//
//  GrowlApplicationController.m
//  Growl
//
//  Created by Karl Adam on Thu Apr 22 2004.
//  Renamed from GrowlController by Mac-arena the Bored Zo on 2005-06-28.
//  Copyright 2004-2006 The Growl Project. All rights reserved.
//
// This file is under the BSD License, refer to License.txt for details

#import "GrowlApplicationController.h"
#import "GrowlPreferencesController.h"
#import "GrowlApplicationTicket.h"
#import "GrowlApplicationNotification.h"
#import "GrowlTicketController.h"
#import "GrowlNotificationTicket.h"
#import "GrowlNotificationDatabase.h"
#import "GrowlNotificationDatabase+GHAAdditions.h"
#import "GrowlPathway.h"
#import "GrowlPathwayController.h"
#import "GrowlPropertyListFilePathway.h"
#import "GrowlPathUtilities.h"
#import "NSStringAdditions.h"
#import "GrowlDisplayPlugin.h"
#import "GrowlPluginController.h"
#import "GrowlIdleStatusController.h"
#import "GrowlDefines.h"
#import "GrowlVersionUtilities.h"
#import "HgRevision.h"
#import "GrowlLog.h"
#import "GrowlNotificationCenter.h"
#import "GrowlImageAdditions.h"
#include "CFGrowlAdditions.h"
#include "CFURLAdditions.h"
#include "CFDictionaryAdditions.h"
#include "CFMutableDictionaryAdditions.h"
#include <SystemConfiguration/SystemConfiguration.h>
#include <sys/errno.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/fcntl.h>
#include <netinet/in.h>
#include <arpa/inet.h>

//XXX Networking; move me
#import "AsyncSocket.h"
#import "GrowlGNTPOutgoingPacket.h"
//#import "GrowlTCPPathway.h"
#import "GrowlNotificationGNTPPacket.h"
#import "GrowlRegisterGNTPPacket.h"
#import "GrowlGNTPPacketParser.h"
#import "GrowlGNTPPacket.h"

#import "GNTPKey.h"
#import "GrowlGNTPKeyController.h"

#import "SparkleHelperDefines.h"

// check every 24 hours
#define UPDATE_CHECK_INTERVAL	24.0*3600.0

//Notifications posted by GrowlApplicationController
#define USER_WENT_IDLE_NOTIFICATION       @"User went idle"
#define USER_RETURNED_NOTIFICATION        @"User returned"

extern CFRunLoopRef CFRunLoopGetMain(void);

static void checkVersion(CFRunLoopTimerRef timer, void *context) {
		// only run update check if it's enabled, TODO: maybe remove timer?
		if([[GrowlPreferencesController sharedController] isBackgroundUpdateCheckEnabled])
				[((GrowlApplicationController*)context) timedCheckForUpdates:nil];
	}

@interface GrowlApplicationController (PRIVATE)
- (void) notificationClicked:(NSNotification *)notification;
- (void) notificationTimedOut:(NSNotification *)notification;
@end

@interface NSString (GrowlNetworkingAdditions)

- (BOOL) Growl_isLikelyDomainName;
- (BOOL) Growl_isLikelyIPAddress;

@end

/*applications that go full-screen (games in particular) are expected to capture
 *	whatever display(s) they're using.
 *we [will] use this to notice, and turn on auto-sticky or something (perhaps
 *	to be decided by the user), when this happens.
 */
#if 0
static BOOL isAnyDisplayCaptured(void) {
	BOOL result = NO;

	CGDisplayCount numDisplays;
	CGDisplayErr err = CGGetActiveDisplayList(/*maxDisplays*/ 0U, /*activeDisplays*/ NULL, &numDisplays);
	if (err != noErr)
		[[GrowlLog sharedController] writeToLog:@"Checking for captured displays: Could not count displays: %li", (long)err];
	else {
		CGDirectDisplayID *displays = malloc(numDisplays * sizeof(CGDirectDisplayID));
		CGGetActiveDisplayList(numDisplays, displays, /*numDisplays*/ NULL);

		if (!displays)
			[[GrowlLog sharedController] writeToLog:@"Checking for captured displays: Could not allocate list of displays: %s", strerror(errno)];
		else {
			for (CGDisplayCount i = 0U; i < numDisplays; ++i) {
				if (CGDisplayIsCaptured(displays[i])) {
					result = YES;
					break;
				}
			}

			free(displays);
		}
	}

	return result;
}
#endif

static struct Version version = { 0U, 0U, 0U, releaseType_svn, 0U, };

@implementation GrowlApplicationController

+ (GrowlApplicationController *) sharedController {
	return [self sharedInstance];
}

- (id) initSingleton {
	if ((self = [super initSingleton])) {

		// initialize GrowlPreferencesController before observing GrowlPreferencesChanged
		GrowlPreferencesController *preferences = [GrowlPreferencesController sharedController];

		NSDistributedNotificationCenter *NSDNC = [NSDistributedNotificationCenter defaultCenter];

		[NSDNC addObserver:self
				  selector:@selector(preferencesChanged:)
					  name:GrowlPreferencesChanged
					object:nil];
		[NSDNC addObserver:self
				  selector:@selector(showPreview:)
					  name:GrowlPreview
					object:nil];
		[NSDNC addObserver:self
				  selector:@selector(shutdown:)
					  name:GROWL_SHUTDOWN
					object:nil];
		[NSDNC addObserver:self
				  selector:@selector(replyToPing:)
					  name:GROWL_PING
					object:nil];

		NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
		[nc addObserver:self
			   selector:@selector(notificationClicked:)
				   name:GROWL_NOTIFICATION_CLICKED
				 object:nil];
		[nc addObserver:self
			   selector:@selector(notificationTimedOut:)
				   name:GROWL_NOTIFICATION_TIMED_OUT
				 object:nil];

		ticketController = [GrowlTicketController sharedController];

		[GrowlApplicationBridge setGrowlDelegate:self];
		
		[self versionDictionary];

		NSString *file = [[NSBundle mainBundle] pathForResource:@"GrowlDefaults" ofType:@"plist"];
		NSURL *fileURL = [NSURL fileURLWithPath:file];
		NSDictionary *defaultDefaults = (NSDictionary *)createPropertyListFromURL((NSURL *)fileURL, kCFPropertyListImmutable, NULL, NULL);
		if (defaultDefaults) {
			[preferences registerDefaults:defaultDefaults];
			[defaultDefaults release];
		}

		if ([GrowlPathUtilities runningHelperAppBundle] != [NSBundle mainBundle]) {
			/*We are not the real GHA.
			 *We are another GHA that a pre-1.1.3 GAB has invoked to register an application by a plist file.
			 *This means that we should not start up the pathway controller; we should, instead, start up the plist-file pathway directly, and wait up to one second for -application:openFile: messages, and forward them to the plist-file pathway (as appropriate), and quit one second after the last one.
			 */
			NSLog(@"%@", @"It appears that at least one other instance of Growl is running. This one will quit.");
			quitAfterOpen = YES;
		} else {
			//This class doesn't exist in the prefpane.
			Class pathwayControllerClass = NSClassFromString(@"GrowlPathwayController");
			if (pathwayControllerClass)
				[pathwayControllerClass sharedController];
		}
		
		[self preferencesChanged:nil];

		//TODO: fix this up so that it uses actual settings
		for(NSMutableDictionary *entry in destinations)
		{
			id uuid = [entry objectForKey:@"uuid"];
			GNTPKey *key = [[GrowlGNTPKeyController sharedInstance] keyForUUID:uuid];
			if (uuid && !key) {
				//key = [[GNTPKey alloc] keyWithPassword:@"testing" hashAlgorithm:GNTPSHA512 encryptionAlgorithm:GNTPAES];
            //key = [[GNTPKey alloc] keyWithPassword:@"" hashAlgorithm:GNTPNoHash encryptionAlgorithm:GNTPNone];
            
            NSString *password = nil;
            unsigned char *passwordChars;
            UInt32 passwordLength;
            OSStatus status;
            const char *growlOutgoing = "GrowlOutgoingNetworkConnection";
            const char *computerNameChars = [[entry objectForKey:@"computer"] UTF8String];
            status = SecKeychainFindGenericPassword(NULL,
                                                    (UInt32)strlen(growlOutgoing), growlOutgoing,
                                                    (UInt32)strlen(computerNameChars), computerNameChars,
                                                    &passwordLength, (void **)&passwordChars, NULL);		
            if (status == noErr) {
               password = [[NSString alloc] initWithBytes:passwordChars
                                                   length:passwordLength
                                                 encoding:NSUTF8StringEncoding];
               SecKeychainItemFreeContent(NULL, passwordChars);
            } else {
               if (status != errSecItemNotFound)
                  NSLog(@"Failed to retrieve password for %@ from keychain. Error: %d", [entry objectForKey:@"computer"], status);
               password = nil;
            }
            if (!password){
               NSLog(@"Couldnt find password for %@, try using no security", [entry objectForKey:@"computer"]);
               key = [[GNTPKey alloc] initWithPassword:@"" hashAlgorithm:GNTPNoHash encryptionAlgorithm:GNTPNone];
            }
            else
               key = [[GNTPKey alloc] initWithPassword:password hashAlgorithm:GNTPSHA512 encryptionAlgorithm:GNTPAES];
            
            [password release];
            
				[[GrowlGNTPKeyController sharedInstance] setKey:key forUUID:uuid];
				[key release];
			}
		}
		
		[[[NSWorkspace sharedWorkspace] notificationCenter] addObserver:self
															   selector:@selector(applicationLaunched:)
																   name:NSWorkspaceDidLaunchApplicationNotification
																 object:nil];

		growlIcon = [[NSImage imageNamed:@"NSApplicationIcon"] retain];

		GrowlIdleStatusController_init();
		[nc addObserver:self
			   selector:@selector(idleStatus:)
				   name:@"GrowlIdleStatus"
				 object:nil];
				
		NSDate *lastCheck = [preferences objectForKey:LastUpdateCheckKey];
		NSDate *now = [NSDate date];
		if (!lastCheck || [now timeIntervalSinceDate:lastCheck] > UPDATE_CHECK_INTERVAL) {
			checkVersion(NULL, self);
			lastCheck = now;
		}
		CFRunLoopTimerContext context = {0, self, NULL, NULL, NULL};
		updateTimer = CFRunLoopTimerCreate(kCFAllocatorDefault, [[lastCheck addTimeInterval:UPDATE_CHECK_INTERVAL] timeIntervalSinceReferenceDate], UPDATE_CHECK_INTERVAL, 0, 0, checkVersion, &context);
		CFRunLoopAddTimer(CFRunLoopGetMain(), updateTimer, kCFRunLoopCommonModes);

		[[NSDistributedNotificationCenter defaultCenter] addObserver:self
															selector:@selector(growlSparkleHelperFoundUpdate:)
																name:SPARKLE_HELPER_UPDATE_AVAILABLE
															  object:[[NSBundle mainBundle] bundleIdentifier]
												  suspensionBehavior:NSNotificationSuspensionBehaviorDeliverImmediately];

		
		// create and register GrowlNotificationCenter
		growlNotificationCenter = [[GrowlNotificationCenter alloc] init];
		growlNotificationCenterConnection = [[NSConnection alloc] initWithReceivePort:[NSPort port] sendPort:nil];
		//[growlNotificationCenterConnection enableMultipleThreads];
		[growlNotificationCenterConnection setRootObject:growlNotificationCenter];
		if (![growlNotificationCenterConnection registerName:@"GrowlNotificationCenter"])
			NSLog(@"WARNING: could not register GrowlNotificationCenter for interprocess access");
         
      [[GrowlNotificationDatabase sharedInstance] setupMaintenanceTimers];
      
	}

	return self;
}

- (void) idleStatus:(NSNotification *)notification {
	if ([[notification object] isEqualToString:@"Idle"]) {
      
		GrowlPreferencesController *preferences = [GrowlPreferencesController sharedController];
		int idleThreshold;
		NSNumber *value = [preferences objectForKey:@"IdleThreshold"];
		NSString *description;

		idleThreshold = (value ? [value intValue] : MACHINE_IDLE_THRESHOLD);
		description = [NSString stringWithFormat:NSLocalizedString(@"No activity for more than %d seconds.", nil), idleThreshold];
		if ([preferences stickyWhenAway])
			description = [description stringByAppendingString:NSLocalizedString(@" New notifications will be sticky.", nil)];

		[GrowlApplicationBridge notifyWithTitle:NSLocalizedString(@"User went idle", nil)
									description:description
							   notificationName:USER_WENT_IDLE_NOTIFICATION
									   iconData:growlIconData
									   priority:-1
									   isSticky:NO
								   clickContext:nil
									 identifier:nil];
	} else {
		[GrowlApplicationBridge notifyWithTitle:NSLocalizedString(@"User returned", nil)
									description:NSLocalizedString(@"User activity detected. New notifications will not be sticky by default.", nil)
							   notificationName:USER_RETURNED_NOTIFICATION
									   iconData:growlIconData
									   priority:-1
									   isSticky:NO
								   clickContext:nil
									 identifier:nil];
	}
}

- (void) destroy {
	//free your world
	[mainThread release]; mainThread = nil;
	Class pathwayControllerClass = NSClassFromString(@"GrowlPathwayController");
	if (pathwayControllerClass)
		[(id)[pathwayControllerClass sharedController] setServerEnabled:NO];
	[destinations     release]; destinations = nil;
	[growlIcon        release]; growlIcon = nil;
	[defaultDisplayPlugin release]; defaultDisplayPlugin = nil;

	GrowlIdleStatusController_dealloc();

	CFRunLoopTimerInvalidate(updateTimer);
	CFRelease(updateTimer);

	[[NSNotificationCenter defaultCenter] removeObserver:self name:nil object:nil];
	[[NSDistributedNotificationCenter defaultCenter] removeObserver:self name:nil object:nil];
	
	[growlNotificationCenterConnection invalidate];
	[growlNotificationCenterConnection release]; growlNotificationCenterConnection = nil;
	[growlNotificationCenter           release]; growlNotificationCenter = nil;
	
	[super destroy];
}

#pragma mark Guts

- (void) showPreview:(NSNotification *) note {
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	NSString *displayName = [note object];
	GrowlDisplayPlugin *displayPlugin = (GrowlDisplayPlugin *)[[GrowlPluginController sharedController] displayPluginInstanceWithName:displayName author:nil version:nil type:nil];

	NSString *desc = [[NSString alloc] initWithFormat:NSLocalizedString(@"This is a preview of the %@ display", "Preview message shown when clicking Preview in the system preferences pane. %@ becomes the name of the display style being used."), displayName];
	NSNumber *priority = [[NSNumber alloc] initWithInt:0];
	NSNumber *sticky = [[NSNumber alloc] initWithBool:NO];
	NSDictionary *info = [[NSDictionary alloc] initWithObjectsAndKeys:
		@"Growl",   GROWL_APP_NAME,
		@"Preview", GROWL_NOTIFICATION_NAME,
		NSLocalizedString(@"Preview", "Title of the Preview notification shown to demonstrate Growl displays"), GROWL_NOTIFICATION_TITLE,
		desc,       GROWL_NOTIFICATION_DESCRIPTION,
		priority,   GROWL_NOTIFICATION_PRIORITY,
		sticky,     GROWL_NOTIFICATION_STICKY,
		[growlIcon PNGRepresentation],  GROWL_NOTIFICATION_ICON_DATA,
		nil];
	[desc     release];
	[priority release];
	[sticky   release];
	GrowlApplicationNotification *notification = [[GrowlApplicationNotification alloc] initWithDictionary:info];
	[info release];
	[displayPlugin displayNotification:notification];
	[notification release];
	[pool release];
}


/* XXX This network stuff shouldn't be in GrowlApplicationController! */

/*!
 * @brief Get address data for a Growl server
 *
 * @param name The name of the server
 * @result An NSData which contains a (struct sockaddr *)'s data. This may actually be a sockaddr_in or a sockaddr_in6.
 */
- (NSData *)addressDataForGrowlServerOfType:(NSString *)type withName:(NSString *)name
{
	if ([name hasSuffix:@".local"])
		name = [name substringWithRange:NSMakeRange(0, [name length] - [@".local" length])];

	if ([name Growl_isLikelyDomainName]) {
		CFHostRef host = CFHostCreateWithName(kCFAllocatorDefault, (CFStringRef)name);
		CFStreamError error;
		if (CFHostStartInfoResolution(host, kCFHostAddresses, &error)) {
			NSArray *addresses = (NSArray *)CFHostGetAddressing(host, NULL);
			
			if ([addresses count]) {
				/* DNS lookup success! */
				return [addresses objectAtIndex:0];
			}
		}
		if (host) CFRelease(host);
		
	} else if ([name Growl_isLikelyIPAddress]) {
		struct sockaddr_in serverAddr;
		
		memset(&serverAddr, 0, sizeof(serverAddr));
		serverAddr.sin_family = AF_INET;
		serverAddr.sin_addr.s_addr = inet_addr([name UTF8String]);
		serverAddr.sin_port = htons(GROWL_TCP_PORT);
		NSLog(@"address: %@", [name UTF8String]);
		return [NSData dataWithBytes:&serverAddr length:serverAddr.sin_len];
	} 
	
	/* If we make it here, treat it as a computer name on the local network */ 
	NSNetService *service = [[[NSNetService alloc] initWithDomain:@"local." type:type name:name] autorelease];
	if (!service) {
		/* No such service exists. The computer is probably offline. */
		return nil;
	}
	
	/* Work for 8 seconds to resolve the net service to an IP and port. We should be running
	 * on a thread, so blocking is fine.
	 */
	[service scheduleInRunLoop:[NSRunLoop currentRunLoop] forMode:@"PrivateGrowlMode"];
	[service resolveWithTimeout:8.0];
	CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + 8.0;
	CFTimeInterval remaining;
	while ((remaining = (deadline - CFAbsoluteTimeGetCurrent())) > 0 && [[service addresses] count] == 0) {
		CFRunLoopRunInMode((CFStringRef)@"PrivateGrowlMode", remaining, true);
	}
	[service stop];
	
	NSArray *addresses = [service addresses];
	if (![addresses count]) {
		/* Lookup failed */
		return nil;
	}
	
	return [addresses objectAtIndex:0];
}	

/*
 This will be called whenever AsyncSocket is about to disconnect. In Echo Server,
 it does not do anything other than report what went wrong (this delegate method
 is the only place to get that information), but in a more serious app, this is
 a good place to do disaster-recovery by getting partially-read data. This is
 not, however, a good place to do cleanup. The socket must still exist when this
 method returns.
 */
-(void) onSocket:(AsyncSocket *)sock willDisconnectWithError:(NSError *)err
{
	if (err != nil)
		NSLog (@"Socket %@ will disconnect. Error domain %@, code %d (%@).",
			   sock,
			   [err domain], [err code], [err localizedDescription]);
	else
		NSLog (@"Socket will disconnect. No error.");
	
	NSLog(@"Releasing %@", sock);
	[sock release];
}

- (void)onSocket:(AsyncSocket *)sock didConnectToHost:(NSString *)host port:(UInt16)port
{
	NSLog(@"Connected to %@ on %@:%hu", sock, host, port);
}

- (void)mainThread_sendViaTCP:(NSDictionary *)sendingDetails
{
	
	[[GrowlGNTPPacketParser sharedParser] sendPacket:[sendingDetails objectForKey:@"Packet"]
										   toAddress:[sendingDetails objectForKey:@"Destination"]];
}

// Need run loop to run
// Need to retain AsyncSocket until its work is complete
- (void)sendViaTCP:(GrowlGNTPOutgoingPacket *)packet
{
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
//	NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
//	NSNumber *requestTimeout = [defaults objectForKey:@"ForwardingRequestTimeout"];
//	NSNumber *replyTimeout = [defaults objectForKey:@"ForwardingReplyTimeout"];

	for(NSDictionary *entry in destinations) {
		if ([[entry objectForKey:@"use"] boolValue]) {
			NSLog(@"Looking up address for %@", [entry objectForKey:@"computer"]);
			NSData *destAddress = [self addressDataForGrowlServerOfType:@"_gntp._tcp." withName:[entry objectForKey:@"computer"]];
			if (!destAddress) {
				/* No destination address. Nothing to see here; move along. */
				NSLog(@"Could not obtain destination address for %@", [entry objectForKey:@"computer"]);
				continue;
			}
			GNTPKey *key = [[GrowlGNTPKeyController sharedInstance] keyForUUID:[entry objectForKey:@"uuid"]];
			[packet setKey:key];
			//NSMutableData *result = [NSMutableData data];
			//for(id item in [packet outgoingItems])
			//	[result appendData:[item GNTPRepresentation]];
			//NSLog(@"Sending %@", HexUnencode(HexEncode(result)));
			[self performSelectorOnMainThread:@selector(mainThread_sendViaTCP:)
								   withObject:[NSDictionary dictionaryWithObjectsAndKeys:
											   destAddress, @"Destination",
											   packet, @"Packet",
											   nil]
								waitUntilDone:NO];
		} else {
			NSLog(@"6  destination %@", entry);
		}
	}

	[pool release];	
}

- (void) forwardNotification:(NSDictionary *)dict
{
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

	GrowlGNTPOutgoingPacket *outgoingPacket = [GrowlGNTPOutgoingPacket outgoingPacketOfType:GrowlGNTPOutgoingPacket_NotifyType
																					forDict:dict];
	[self sendViaTCP:outgoingPacket];
   
	[pool release];
}
	
- (void) forwardRegistration:(NSDictionary *)dict
{
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

	GrowlGNTPOutgoingPacket *outgoingPacket = [GrowlGNTPOutgoingPacket outgoingPacketOfType:GrowlGNTPOutgoingPacket_RegisterType
																					forDict:dict];
	[self sendViaTCP:outgoingPacket];

	[pool release];
}
	
#pragma mark Retrieving sounds

- (OSStatus) getFSRef:(out FSRef *)outRef forSoundNamed:(NSString *)soundName {
	BOOL foundIt = NO;

	NSArray *soundTypes = [NSSound soundUnfilteredFileTypes];

	//Throw away all the HFS types, leaving only filename extensions.
	NSPredicate *noHFSTypesPredicate = [NSPredicate predicateWithFormat:@"NOT (self BEGINSWITH \"'\")"];
	soundTypes = [soundTypes filteredArrayUsingPredicate:noHFSTypesPredicate];

	//If there are no types left, abort.
	if ([soundTypes count] == 0U)
		return unknownFormatErr;

	//We only want the filename extensions, not the HFS types.
	//Also, we want the longest one last so that we can use lastObject's length to allocate the buffer.
	NSSortDescriptor *sortDesc = [[[NSSortDescriptor alloc] initWithKey:@"length" ascending:YES] autorelease];
	NSArray *sortDescs = [NSArray arrayWithObject:sortDesc];
	soundTypes = [soundTypes sortedArrayUsingDescriptors:sortDescs];

	NSMutableArray *filenames = [NSMutableArray arrayWithCapacity:[soundTypes count]];
	for (NSString *soundType in soundTypes) {
		[filenames addObject:[soundName stringByAppendingPathExtension:soundType]];
	}

	//The additions are for appending '.' plus the longest filename extension.
	size_t filenameLen = [soundName length] + 1U + [[soundTypes lastObject] length];
	unichar *filenameBuf = malloc(filenameLen * sizeof(unichar));
	if (!filenameBuf) return memFullErr;

	FSRef folderRef;
	OSStatus err;

	err = FSFindFolder(kUserDomain, kSystemSoundsFolderType, kDontCreateFolder, &folderRef);
	if (err == noErr) {
		//Folder exists. If it didn't, FSFindFolder would have returned fnfErr.
		for (NSString *filename in filenames) {
			[filename getCharacters:filenameBuf];
			err = FSMakeFSRefUnicode(&folderRef, [filename length], filenameBuf, kTextEncodingUnknown, outRef);
			if (err == noErr) {
				foundIt = YES;
				break;
			}
		}
	}

	if (!foundIt) {
		err = FSFindFolder(kLocalDomain, kSystemSoundsFolderType, kDontCreateFolder, &folderRef);
		if (err == noErr) {
			//Folder exists. If it didn't, FSFindFolder would have returned fnfErr.
			for (NSString *filename in filenames) {
				[filename getCharacters:filenameBuf];
				err = FSMakeFSRefUnicode(&folderRef, [filename length], filenameBuf, kTextEncodingUnknown, outRef);
				if (err == noErr) {
					foundIt = YES;
					break;
				}
			}
		}
	}

	if (!foundIt) {
		err = FSFindFolder(kSystemDomain, kSystemSoundsFolderType, kDontCreateFolder, &folderRef);
		if (err == noErr) {
			//Folder exists. If it didn't, FSFindFolder would have returned fnfErr.
			for (NSString *filename in filenames) {
				[filename getCharacters:filenameBuf];
				err = FSMakeFSRefUnicode(&folderRef, [filename length], filenameBuf, kTextEncodingUnknown, outRef);
				if (err == noErr) {
					break;
				}
			}
		}
	}

	free(filenameBuf);

	return err;
}

#pragma mark Dispatching notifications

- (GrowlNotificationResult) dispatchNotificationWithDictionary:(NSDictionary *) dict {
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

	[[GrowlLog sharedController] writeNotificationDictionaryToLog:dict];

	// Make sure this notification is actually registered
	NSString *appName = [dict objectForKey:GROWL_APP_NAME];
	GrowlApplicationTicket *ticket = [ticketController ticketForApplicationName:appName];
	NSString *notificationName = [dict objectForKey:GROWL_NOTIFICATION_NAME];
	if (!ticket) {
		[pool release];
		return GrowlNotificationResultNotRegistered;
	}

	if (![ticket isNotificationAllowed:notificationName]) {
		// Either the app isn't registered or the notification is turned off
		// We should do nothing
		[pool release];
		return GrowlNotificationResultDisabled;
	}

	NSMutableDictionary *aDict = [dict mutableCopy];

	// Check icon
	Class NSImageClass = [NSImage class];
	Class NSDataClass  = [NSData  class];
	NSData *iconData = nil;
	id sourceIconData = [aDict objectForKey:GROWL_NOTIFICATION_ICON_DATA];
	if (sourceIconData) {
		if ([sourceIconData isKindOfClass:NSImageClass])
			iconData = [(NSImage *)sourceIconData PNGRepresentation];
		else if ([sourceIconData isKindOfClass:NSDataClass])
			iconData = sourceIconData;
	}
	if (!iconData)
		iconData = [ticket iconData];

	if (iconData)
		[aDict setObject:iconData forKey:GROWL_NOTIFICATION_ICON_DATA];

	// If app icon present, convert to NSImage
	iconData = nil;
	sourceIconData = [aDict objectForKey:GROWL_NOTIFICATION_APP_ICON_DATA];
	if (sourceIconData) {
		if ([sourceIconData isKindOfClass:NSImageClass])
			iconData = [(NSImage *)sourceIconData PNGRepresentation];
		else if ([sourceIconData isKindOfClass:NSDataClass])
			iconData = sourceIconData;
	}
	if (iconData)
		[aDict setObject:iconData forKey:GROWL_NOTIFICATION_APP_ICON_DATA];

	// To avoid potential exceptions, make sure we have both text and title
	if (![aDict objectForKey:GROWL_NOTIFICATION_DESCRIPTION])
		[aDict setObject:@"" forKey:GROWL_NOTIFICATION_DESCRIPTION];
	if (![aDict objectForKey:GROWL_NOTIFICATION_TITLE])
		[aDict setObject:@"" forKey:GROWL_NOTIFICATION_TITLE];

	//Retrieve and set the the priority of the notification
	GrowlNotificationTicket *notification = [ticket notificationTicketForName:notificationName];
	int priority = [notification priority];
	NSNumber *value;
	if (priority == GrowlPriorityUnset) {
		value = [dict objectForKey:GROWL_NOTIFICATION_PRIORITY];
		if (!value)
			value = [NSNumber numberWithInt:0];
	} else
		value = [NSNumber numberWithInt:priority];
	[aDict setObject:value forKey:GROWL_NOTIFICATION_PRIORITY];

	GrowlPreferencesController *preferences = [GrowlPreferencesController sharedController];

	// Retrieve and set the sticky bit of the notification
	int sticky = [notification sticky];
	if (sticky >= 0)
		setBooleanForKey(aDict, GROWL_NOTIFICATION_STICKY, sticky);
/*	else if ([preferences stickyWhenAway] && !getBooleanForKey(aDict, GROWL_NOTIFICATION_STICKY))
		setBooleanForKey(aDict, GROWL_NOTIFICATION_STICKY, GrowlIdleStatusController_isIdle());*/

	BOOL saveScreenshot = [[NSUserDefaults standardUserDefaults] boolForKey:GROWL_SCREENSHOT_MODE];
	setBooleanForKey(aDict, GROWL_SCREENSHOT_MODE, saveScreenshot);
	setBooleanForKey(aDict, GROWL_CLICK_HANDLER_ENABLED, [ticket clickHandlersEnabled]);

	/* Set a unique ID which we can use globally to identify this particular notification if it doesn't have one */
	if (![aDict objectForKey:GROWL_NOTIFICATION_INTERNAL_ID]) {
		CFUUIDRef uuidRef = CFUUIDCreate(kCFAllocatorDefault);
		NSString *uuid = (NSString *)CFUUIDCreateString(kCFAllocatorDefault, uuidRef);
		[aDict setValue:uuid
				 forKey:GROWL_NOTIFICATION_INTERNAL_ID];
		[uuid release];
		CFRelease(uuidRef);
	}
   
   GrowlApplicationNotification *appNotification = [[GrowlApplicationNotification alloc] initWithDictionary:aDict];

   [[GrowlNotificationDatabase sharedInstance] logNotificationWithDictionary:aDict];
   
   if([preferences isForwardingEnabled])
      [self performSelectorInBackground:@selector(forwardNotification:) withObject:[dict copy]];
   
	if (![preferences squelchMode]) {
		GrowlDisplayPlugin *display = [notification displayPlugin];

		if (!display)
			display = [ticket displayPlugin];

		if (!display) {
			if (!defaultDisplayPlugin) {
				NSString *displayPluginName = [[GrowlPreferencesController sharedController] defaultDisplayPluginName];
				defaultDisplayPlugin = [(GrowlDisplayPlugin *)[[GrowlPluginController sharedController] displayPluginInstanceWithName:displayPluginName author:nil version:nil type:nil] retain];
				if (!defaultDisplayPlugin) {
					//User's selected default display has gone AWOL. Change to the default default.
					NSString *file = [[NSBundle mainBundle] pathForResource:@"GrowlDefaults" ofType:@"plist"];
					NSURL *fileURL = [NSURL fileURLWithPath:file];
					NSDictionary *defaultDefaults = (NSDictionary *)createPropertyListFromURL((NSURL *)fileURL, kCFPropertyListImmutable, NULL, NULL);
					if (defaultDefaults) {
						displayPluginName = [defaultDefaults objectForKey:GrowlDisplayPluginKey];
						if (!displayPluginName)
							GrowlLog_log(@"No default display specified in default preferences! Perhaps your Growl installation is corrupted?");
						else {
							defaultDisplayPlugin = (GrowlDisplayPlugin *)[[[GrowlPluginController sharedController] displayPluginDictionaryWithName:displayPluginName author:nil version:nil type:nil] pluginInstance];

							//Now fix the user's preferences to forget about the missing display plug-in.
							[preferences setObject:displayPluginName forKey:GrowlDisplayPluginKey];
						}

						[defaultDefaults release];
					}
				}
			}
			display = defaultDisplayPlugin;
		}
      
		[display displayNotification:appNotification];


		NSString *soundName = [notification sound];
		if (soundName) {
			NSError *error = nil;
			NSDictionary *userInfo;

			FSRef soundRef;
			OSStatus err = [self getFSRef:&soundRef forSoundNamed:soundName];
			if (err == noErr) {
			} else {
				userInfo = [NSDictionary dictionaryWithObjectsAndKeys:
					[NSString stringWithFormat:NSLocalizedString(@"Could not find sound file named \"%@\": %s", /*comment*/ nil), soundName, GetMacOSStatusCommentString(err)], NSLocalizedDescriptionKey,
					nil];
			}

			if (err != noErr) {
				error = [NSError errorWithDomain:NSOSStatusErrorDomain code:err userInfo:userInfo];
				[NSApp presentError:error];
			}
		}
	}
   
   [appNotification release];
   
	// send to DO observers
	[growlNotificationCenter notifyObservers:aDict];

	[aDict release];
	[pool release];
	
	return GrowlNotificationResultPosted;
}

- (BOOL) registerApplicationWithDictionary:(NSDictionary *)userInfo {
	[[GrowlLog sharedController] writeRegistrationDictionaryToLog:userInfo];

	NSString *appName = [userInfo objectForKey:GROWL_APP_NAME];

	GrowlApplicationTicket *newApp = [ticketController ticketForApplicationName:appName];

	if (newApp) {
		[newApp reregisterWithDictionary:userInfo];
	} else {
		newApp = [[[GrowlApplicationTicket alloc] initWithDictionary:userInfo] autorelease];
	}

	BOOL success = YES;

	if (appName && newApp) {
		if ([newApp hasChanged])
			[newApp saveTicket];
		[ticketController addTicket:newApp];

	} else { //!(appName && newApp)
		NSString *filename = [(appName ? appName : @"unknown-application") stringByAppendingPathExtension:GROWL_REG_DICT_EXTENSION];

		//We'll be writing the file to ~/Library/Logs/Failed Growl registrations.
		NSFileManager *mgr = [NSFileManager defaultManager];
		NSString *userLibraryFolder = [NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, /*expandTilde*/ YES) lastObject];
		NSString *logsFolder = [userLibraryFolder stringByAppendingPathComponent:@"Logs"];
		[mgr createDirectoryAtPath:logsFolder attributes:nil];
		NSString *failedTicketsFolder = [logsFolder stringByAppendingPathComponent:@"Failed Growl registrations"];
		[mgr createDirectoryAtPath:failedTicketsFolder attributes:nil];
		NSString *path = [failedTicketsFolder stringByAppendingPathComponent:filename];

		//NSFileHandle will not create the file for us, so we must create it separately.
		[mgr createFileAtPath:path contents:nil attributes:nil];

		NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
		[fh seekToEndOfFile];
		if ([fh offsetInFile]) //we are not at the beginning of the file
			[fh writeData:[@"\n---\n\n" dataUsingEncoding:NSUTF8StringEncoding]];
		[fh writeData:[[[userInfo description] stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding]];
		[fh closeFile];

		if (!appName) appName = @"with no name";

		NSLog(@"Failed application registration for application %@; wrote failed registration dictionary %p to %@", appName, userInfo, path);
		success = NO;
	}
   
   if([[GrowlPreferencesController sharedController] isForwardingEnabled])
      [self performSelectorInBackground:@selector(forwardRegistration:) withObject:[userInfo copy]];
   
	return success;
}

#pragma mark Version of Growl

+ (NSString *) growlVersion {
	return [[NSBundle mainBundle] objectForInfoDictionaryKey:(NSString *)kCFBundleVersionKey];
}

- (NSDictionary *) versionDictionary {
	if (!versionInfo) {
		NSString *versionString = [[NSBundle mainBundle] objectForInfoDictionaryKey:(NSString *)kCFBundleVersionKey];
		BOOL parseSucceeded = parseVersionString(versionString, &version);
		NSAssert1(parseSucceeded, @"Could not parse version string: %@", versionString);

		if (version.releaseType == releaseType_svn)
			version.development = (u_int32_t)HG_REVISION;

		NSNumber *major = [[NSNumber alloc] initWithUnsignedShort:version.major];
		NSNumber *minor = [[NSNumber alloc] initWithUnsignedShort:version.minor];
		NSNumber *incremental = [[NSNumber alloc] initWithUnsignedChar:version.incremental];
		NSNumber *releaseType = [[NSNumber alloc] initWithUnsignedChar:version.releaseType];
		NSNumber *development = [[NSNumber alloc] initWithUnsignedShort:version.development];

		versionInfo = [[NSDictionary alloc] initWithObjectsAndKeys:
			[GrowlApplicationController growlVersion], (NSString *)kCFBundleVersionKey,

			major,                                     @"Major version",
			minor,                                     @"Minor version",
			incremental,                               @"Incremental version",
			releaseTypeNames[version.releaseType],     @"Release type name",
			releaseType,                               @"Release type",
			development,                               @"Development version",

			nil];

		[major       release];
		[minor       release];
		[incremental release];
		[releaseType release];
		[development release];
	}
	return versionInfo;
}

//this method could be moved to Growl.framework, I think.
//pass nil to get GrowlHelperApp's version as a string.
- (NSString *)stringWithVersionDictionary:(NSDictionary *)d {
	if (!d)
		d = [self versionDictionary];

	//0.6
	NSMutableString *result = [NSMutableString stringWithFormat:@"%@.%@",
		[d objectForKey:@"Major version"],
		[d objectForKey:@"Minor version"]];

	//the .1 in 0.6.1
	NSNumber *incremental = [d objectForKey:@"Incremental version"];
	if ([incremental unsignedShortValue])
		[result appendFormat:@".%@", incremental];

	NSString *releaseTypeName = [d objectForKey:@"Release type name"];
	if ([releaseTypeName length]) {
		//"" (release), "b4", " SVN 900"
		[result appendFormat:@"%@%@", releaseTypeName, [d objectForKey:@"Development version"]];
	}

	return result;
}

#pragma mark Accessors

- (BOOL) quitAfterOpen {
	return quitAfterOpen;
}
- (void) setQuitAfterOpen:(BOOL)flag {
	quitAfterOpen = flag;
}

#pragma mark Sparkle Updates

- (void) timedCheckForUpdates:(NSNotification*)note {
	[self launchSparkleHelper];
	[[NSDistributedNotificationCenter defaultCenter] postNotificationName:SPARKLE_HELPER_INTERVAL_INITIATED object:nil userInfo:nil deliverImmediately:YES];
}

- (void) growlNotificationWasClicked:(id)clickContext {
   if ([clickContext isEqualToString:UPDATE_AVAILABLE_NOTIFICATION]) {
      [self launchSparkleHelper];
      [[NSDistributedNotificationCenter defaultCenter] postNotificationName:SPARKLE_HELPER_USER_INITIATED object:nil userInfo:nil deliverImmediately:YES];
   }
}

- (void) growlNotificationTimedOut:(id)clickContext {
   if ([clickContext isEqualToString:UPDATE_AVAILABLE_NOTIFICATION])
   {
      [[NSDistributedNotificationCenter defaultCenter] postNotificationName:SPARKLE_HELPER_DIE 
                                                                     object:nil 
                                                                   userInfo:nil 
                                                         deliverImmediately:YES];
   }
} 

- (void) launchSparkleHelper {
	LSLaunchFSRefSpec spec;
	FSRef appRef;
	OSStatus status = FSPathMakeRef((UInt8 *)[[[GrowlPathUtilities growlPrefPaneBundle] pathForResource:@"GrowlSparkleHelper" ofType:@"app"] fileSystemRepresentation], &appRef, NULL);
	if (status == noErr) {
		
		spec.appRef = &appRef;
		spec.numDocs = 0;
		spec.itemRefs = NULL;
		spec.passThruParams = NULL;
		spec.launchFlags = kLSLaunchDontAddToRecents | kLSLaunchDontSwitch | kLSLaunchNoParams | kLSLaunchAsync;
		spec.asyncRefCon = NULL;
		status = LSOpenFromRefSpec(&spec, NULL);
	}
}

- (void) growlSparkleHelperFoundUpdate:(NSNotification*)note {
	CFStringRef title = CFCopyLocalizedString(CFSTR("Update Available"), /*comment*/ NULL);
	CFStringRef description = CFCopyLocalizedString(CFSTR("A newer version of Growl is available online. Click here to download it now."), /*comment*/ NULL);
	[GrowlApplicationBridge notifyWithTitle:(NSString *)title
								description:(NSString *)description
						   notificationName:UPDATE_AVAILABLE_NOTIFICATION
								   iconData:[self applicationIconDataForGrowl]
								   priority:1
								   isSticky:YES
							   clickContext:UPDATE_AVAILABLE_NOTIFICATION
								 identifier:UPDATE_AVAILABLE_NOTIFICATION];
	CFRelease(title);
	CFRelease(description);
}

#pragma mark What NSThread should implement as a class method

- (NSThread *)mainThread {
	return mainThread;
}

#pragma mark Notifications (not the Growl kind)

- (void) preferencesChanged:(NSNotification *) note {
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

	//[note object] is the changed key. A nil key means reload our tickets.
	id object = [note object];

	if (!quitAfterOpen) {
		if (!note || (object && [object isEqual:GrowlStartServerKey])) {
			Class pathwayControllerClass = NSClassFromString(@"GrowlPathwayController");
			if (pathwayControllerClass)
				[(id)[pathwayControllerClass sharedController] setServerEnabledFromPreferences];
		}
	}
	if (!note || (object && [object isEqual:GrowlUserDefaultsKey]))
		[[GrowlPreferencesController sharedController] synchronize];
	if (!note || (object && [object isEqual:GrowlEnabledKey]))
		growlIsEnabled = [[GrowlPreferencesController sharedController] boolForKey:GrowlEnabledKey];
	if (!note || (object && [object isEqual:GrowlEnableForwardKey]))
		enableForward = [[GrowlPreferencesController sharedController] isForwardingEnabled];
	if (!note || (object && [object isEqual:GrowlForwardDestinationsKey])) {
		[destinations release];
		destinations = [[[GrowlPreferencesController sharedController] objectForKey:GrowlForwardDestinationsKey] retain];
	}
	if (!note || !object)
		[ticketController loadAllSavedTickets];
	if (!note || (object && [object isEqual:GrowlDisplayPluginKey]))
		// force reload
		[defaultDisplayPlugin release];
		defaultDisplayPlugin = nil;
	if (object) {
		if ([object isEqual:@"GrowlTicketDeleted"]) {
			NSString *ticketName = [[note userInfo] objectForKey:@"TicketName"];
			[ticketController removeTicketForApplicationName:ticketName];
		} else if ([object isEqual:@"GrowlTicketChanged"]) {
			NSString *ticketName = [[note userInfo] objectForKey:@"TicketName"];
			GrowlApplicationTicket *newTicket = [[GrowlApplicationTicket alloc] initTicketForApplication:ticketName];
			if (newTicket) {
				[ticketController addTicket:newTicket];
				[newTicket release];
			}
		} else if ((!quitAfterOpen) && [object isEqual:GrowlUDPPortKey]) {
			Class pathwayControllerClass = NSClassFromString(@"GrowlPathwayController");
			if (pathwayControllerClass) {
				id pathwayController = [pathwayControllerClass sharedController];
				[pathwayController setServerEnabled:NO];
				[pathwayController setServerEnabled:YES];
			}
		}
	}
	
	[pool release];
}

- (void) shutdown:(NSNotification *) note {
	[NSApp terminate:nil];
}

- (void) replyToPing:(NSNotification *) note {
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

	[[NSDistributedNotificationCenter defaultCenter] postNotificationName:GROWL_PONG
	                                                               object:nil
	                                                             userInfo:nil
	                                                   deliverImmediately:NO];
	
	[pool release];
}

#pragma mark NSApplication Delegate Methods

- (BOOL) application:(NSApplication *)theApplication openFile:(NSString *)filename {
	BOOL retVal = NO;
	NSString *pathExtension = [filename pathExtension];

	if ([pathExtension isEqualToString:GROWL_REG_DICT_EXTENSION]) {
		//If the auto-quit flag is set, it's probably because we are not the real GHA�we're some other GHA that a broken (pre-1.1.3) GAB opened this file with. If that's the case, find the real one and open the file with it.
		BOOL registerItOurselves = YES;
		NSString *realHelperAppBundlePath = nil;

		if (quitAfterOpen) {
			//But, just to make sure we don't infinitely loop, make sure this isn't our own bundle.
			NSString *ourBundlePath = [[NSBundle mainBundle] bundlePath];
			realHelperAppBundlePath = [[GrowlPathUtilities runningHelperAppBundle] bundlePath];
			if (![ourBundlePath isEqualToString:realHelperAppBundlePath])
				registerItOurselves = NO;
		}

		if (registerItOurselves) {
			//We are the real GHA.
			//Have the property-list-file pathway process this registration dictionary file.
			GrowlPropertyListFilePathway *pathway = [GrowlPropertyListFilePathway standardPathway];
			[pathway application:theApplication openFile:filename];
		} else {
			//We're definitely not the real GHA, so pass it to the real GHA to be registered.
			[[NSWorkspace sharedWorkspace] openFile:filename
									withApplication:realHelperAppBundlePath];
		}
	} else {
		GrowlPluginController *controller = [GrowlPluginController sharedController];
		//the set returned by GrowlPluginController is case-insensitive. yay!
		if ([[controller registeredPluginTypes] containsObject:pathExtension]) {
			[controller installPluginFromPath:filename];

			retVal = YES;
		}
	}

	/*If Growl is not enabled and was not already running before
	 *	(for example, via an autolaunch even though the user's last
	 *	preference setting was to click "Stop Growl," setting enabled to NO),
	 *	quit having registered; otherwise, remain running.
	 */
	if (!growlIsEnabled && !growlFinishedLaunching) {
		//Terminate after one second to give us time to process any other openFile: messages.
		[NSObject cancelPreviousPerformRequestsWithTarget:NSApp
												 selector:@selector(terminate:)
												   object:nil];
		[NSApp performSelector:@selector(terminate:)
					withObject:nil
					afterDelay:1.0];
	}

	return retVal;
}

- (void) applicationWillFinishLaunching:(NSNotification *)aNotification {
	mainThread = [[NSThread currentThread] retain];

	BOOL printVersionAndExit = [[NSUserDefaults standardUserDefaults] boolForKey:@"PrintVersionAndExit"];
	if (printVersionAndExit) {
		printf("This is GrowlHelperApp version %s.\n"
			   "PrintVersionAndExit was set to %hhi, so GrowlHelperApp will now exit.\n",
			   [[self stringWithVersionDictionary:nil] UTF8String],
			   printVersionAndExit);
		[NSApp terminate:nil];
	}

	NSFileManager *fs = [NSFileManager defaultManager];

	NSString *destDir, *subDir;
	NSArray *searchPath = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, /*expandTilde*/ YES);

	destDir = [searchPath objectAtIndex:0U]; //first == last == ~/Library
	[fs createDirectoryAtPath:destDir attributes:nil];
	destDir = [destDir stringByAppendingPathComponent:@"Application Support"];
	[fs createDirectoryAtPath:destDir attributes:nil];
	destDir = [destDir stringByAppendingPathComponent:@"Growl"];
	[fs createDirectoryAtPath:destDir attributes:nil];

	subDir  = [destDir stringByAppendingPathComponent:@"Tickets"];
	[fs createDirectoryAtPath:subDir attributes:nil];
	subDir  = [destDir stringByAppendingPathComponent:@"Plugins"];
	[fs createDirectoryAtPath:subDir attributes:nil];
}

//Post a notification when we are done launching so the application bridge can inform participating applications
- (void) applicationDidFinishLaunching:(NSNotification *)aNotification {
	[[NSDistributedNotificationCenter defaultCenter] postNotificationName:GROWL_IS_READY
	                                                               object:nil
	                                                             userInfo:nil
	                                                   deliverImmediately:YES];
	growlFinishedLaunching = YES;

	if (quitAfterOpen) {
		//We provide a delay of 1 second to give NSApp time to send us application:openFile: messages for any .growlRegDict files the GrowlPropertyListFilePathway needs to process.
		[NSApp performSelector:@selector(terminate:)
					withObject:nil
					afterDelay:1.0];
	} else {
		/*If Growl is not enabled and was not already running before
		 *	(for example, via an autolaunch even though the user's last
		 *	preference setting was to click "Stop Growl," setting enabled to NO),
		 *	quit having registered; otherwise, remain running.
		 */
		if (!growlIsEnabled)
			[NSApp terminate:nil];
	}
}

//Same as applicationDidFinishLaunching, called when we are asked to reopen (that is, we are already running)
- (BOOL) applicationShouldHandleReopen:(NSApplication *)theApplication hasVisibleWindows:(BOOL)flag {
	return NO;
}

- (BOOL) applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)theApplication {
	return NO;
}

- (void) applicationWillTerminate:(NSNotification *)notification {
	// kill sparkle helper if it's still running
	[[NSDistributedNotificationCenter defaultCenter] postNotificationName:SPARKLE_HELPER_DIE object:nil userInfo:nil deliverImmediately:YES];
	[GrowlAbstractSingletonObject destroyAllSingletons];	//Release all our controllers
}

#pragma mark Auto-discovery

//called by NSWorkspace when an application launches.
- (void) applicationLaunched:(NSNotification *)notification {
	NSDictionary *userInfo = [notification userInfo];

	if (!userInfo)
		return;

	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	NSString *appPath = [userInfo objectForKey:@"NSApplicationPath"];

	if (appPath) {
		NSString *ticketPath = [NSBundle pathForResource:@"Growl Registration Ticket" ofType:GROWL_REG_DICT_EXTENSION inDirectory:appPath];
		if (ticketPath) {
			CFURLRef ticketURL = CFURLCreateWithFileSystemPath(kCFAllocatorDefault, (CFStringRef)ticketPath, kCFURLPOSIXPathStyle, false);
			NSMutableDictionary *ticket = (NSMutableDictionary *)createPropertyListFromURL((NSURL *)ticketURL, kCFPropertyListMutableContainers, NULL, NULL);

			if (ticket) {
				NSString *appName = [userInfo objectForKey:@"NSApplicationName"];

				//set the app's name in the dictionary, if it's not present already.
				if (![ticket objectForKey:GROWL_APP_NAME])
					[ticket setObject:appName forKey:GROWL_APP_NAME];

				if ([GrowlApplicationTicket isValidTicketDictionary:ticket]) {
					NSLog(@"Auto-discovered registration ticket in %@ (located at %@)", appName, appPath);

					/* set the app's location in the dictionary, avoiding costly
					 *	lookups later.
					 */
					NSURL *url = [[NSURL alloc] initFileURLWithPath:appPath];
					NSDictionary *file_data = createDockDescriptionWithURL(url);
					id location = file_data ? [NSDictionary dictionaryWithObject:file_data forKey:@"file-data"] : appPath;
					[file_data release];
					[ticket setObject:location forKey:GROWL_APP_LOCATION];
					[url release];

					//write the new ticket to disk, and be sure to launch this ticket instead of the one in the app bundle.
					CFUUIDRef uuid = CFUUIDCreate(kCFAllocatorDefault);
					CFStringRef uuidString = CFUUIDCreateString(kCFAllocatorDefault, uuid);
					CFRelease(uuid);
					ticketPath = [[NSTemporaryDirectory() stringByAppendingPathComponent:(NSString *)uuidString] stringByAppendingPathExtension:GROWL_REG_DICT_EXTENSION];
					CFRelease(uuidString);
					[ticket writeToFile:ticketPath atomically:NO];

					/* open the ticket with ourselves.
					 * we need to use LS in order to launch it with this specific
					 *	GHA, rather than some other.
					 */
					CFURLRef myURL      = (CFURLRef)copyCurrentProcessURL();
					NSArray *URLsToOpen = [NSArray arrayWithObject:[NSURL fileURLWithPath:ticketPath]];
					struct LSLaunchURLSpec spec = {
						.appURL = myURL,
						.itemURLs = (CFArrayRef)URLsToOpen,
						.passThruParams = NULL,
						.launchFlags = kLSLaunchDontAddToRecents | kLSLaunchDontSwitch | kLSLaunchAsync,
						.asyncRefCon = NULL,
					};
					OSStatus err = LSOpenFromURLSpec(&spec, /*outLaunchedURL*/ NULL);
					if (err != noErr)
						NSLog(@"The registration ticket for %@ could not be opened (LSOpenFromURLSpec returned %li). Pathname for the ticket file: %@", appName, (long)err, ticketPath);
					CFRelease(myURL);
				} else if ([GrowlApplicationTicket isKnownTicketVersion:ticket]) {
					NSLog(@"%@ (located at %@) contains an invalid registration ticket - developer, please consult Growl developer documentation (http://growl.info/documentation/developer/)", appName, appPath);
				} else {
					NSNumber *versionNum = [ticket objectForKey:GROWL_TICKET_VERSION];
					if (versionNum)
						NSLog(@"%@ (located at %@) contains a ticket whose format version (%i) is unrecognised by this version (%@) of Growl", appName, appPath, [versionNum intValue], [self stringWithVersionDictionary:nil]);
					else
						NSLog(@"%@ (located at %@) contains a ticket with no format version number; Growl requires that a registration dictionary include a format version number, so that Growl knows whether it will understand the dictionary's format. This ticket will be ignored.", appName, appPath);
				}
				[ticket release];
			}
			CFRelease(ticketURL);
		}
	}

	[pool release];
}

#pragma mark Growl Application Bridge delegate
/*!
 * @brief Returns the application name Growl will use
 */
- (NSString *)applicationNameForGrowl
{
	return @"Growl";
}

- (NSDictionary *)registrationDictionaryForGrowl
{	
	NSDictionary *descriptions = [NSDictionary dictionaryWithObjectsAndKeys:
		NSLocalizedString(@"A Growl update is available", nil), UPDATE_AVAILABLE_NOTIFICATION,
		NSLocalizedString(@"You are now considered idle by Growl", nil), USER_WENT_IDLE_NOTIFICATION,
		NSLocalizedString(@"You are no longer considered idle by Growl", nil), USER_RETURNED_NOTIFICATION,
		nil];

	NSDictionary *humanReadableNames = [NSDictionary dictionaryWithObjectsAndKeys:
		NSLocalizedString(@"Growl update available", nil), UPDATE_AVAILABLE_NOTIFICATION,
		NSLocalizedString(@"User went idle", nil), USER_WENT_IDLE_NOTIFICATION,
		NSLocalizedString(@"User returned", nil), USER_RETURNED_NOTIFICATION,
		nil];
	
	NSDictionary	*growlReg = [NSDictionary dictionaryWithObjectsAndKeys:
		[NSArray arrayWithObjects:UPDATE_AVAILABLE_NOTIFICATION, USER_WENT_IDLE_NOTIFICATION, USER_RETURNED_NOTIFICATION, nil], GROWL_NOTIFICATIONS_ALL,
		[NSArray arrayWithObjects:UPDATE_AVAILABLE_NOTIFICATION, nil], GROWL_NOTIFICATIONS_DEFAULT,
		humanReadableNames, GROWL_NOTIFICATIONS_HUMAN_READABLE_NAMES,
		descriptions, GROWL_NOTIFICATIONS_DESCRIPTIONS,
		nil];
	
	return growlReg;
}

- (NSImage *)applicationIconDataForGrowl
{
	return [NSImage imageNamed:@"growl-icon"];
}

/*click feedback comes here first. GAB picks up the DN and calls our
 *	-growlNotificationWasClicked:/-growlNotificationTimedOut: with it if it's a
 *	GHA notification.
 */
- (void)growlNotificationDict:(NSDictionary *)growlNotificationDict didCloseViaNotificationClick:(BOOL)viaClick onLocalMachine:(BOOL)wasLocal
{
	static BOOL isClosingFromRemoteClick = NO;
	/* Don't post a second close notification on the local machine if we close a notification from this method in
	 * response to a click on a remote machine.
	 */
	if (isClosingFromRemoteClick)
		return;
	
	id clickContext = [growlNotificationDict objectForKey:GROWL_NOTIFICATION_CLICK_CONTEXT];
	if (clickContext) {
		NSString *suffix, *growlNotificationClickedName;
		NSDictionary *clickInfo;
		
		NSString *appName = [growlNotificationDict objectForKey:GROWL_APP_NAME];
		GrowlApplicationTicket *ticket = [ticketController ticketForApplicationName:appName];
		
		if (viaClick && [ticket clickHandlersEnabled]) {
			suffix = GROWL_DISTRIBUTED_NOTIFICATION_CLICKED_SUFFIX;
		} else {
			/*
			 * send GROWL_NOTIFICATION_TIMED_OUT instead, so that an application is
			 * guaranteed to receive feedback for every notification.
			 */
			suffix = GROWL_DISTRIBUTED_NOTIFICATION_TIMED_OUT_SUFFIX;
		}
		
		//Build the application-specific notification name
		NSNumber *pid = [growlNotificationDict objectForKey:GROWL_APP_PID];
		if (pid)
			growlNotificationClickedName = [[NSString alloc] initWithFormat:@"%@-%@-%@",
											appName, pid, suffix];
		else
			growlNotificationClickedName = [[NSString alloc] initWithFormat:@"%@%@",
											appName, suffix];
		clickInfo = [NSDictionary dictionaryWithObject:clickContext
												forKey:GROWL_KEY_CLICKED_CONTEXT];
		[[NSDistributedNotificationCenter defaultCenter] postNotificationName:growlNotificationClickedName
																	   object:nil
																	 userInfo:clickInfo
														   deliverImmediately:YES];
		[growlNotificationClickedName release];
	}
	
	if (!wasLocal) {
		isClosingFromRemoteClick = YES;
		[[NSNotificationCenter defaultCenter] postNotificationName:GROWL_CLOSE_NOTIFICATION
															object:[growlNotificationDict objectForKey:GROWL_NOTIFICATION_INTERNAL_ID]];
		isClosingFromRemoteClick = NO;
	}
}

@end

#pragma mark -

@implementation GrowlApplicationController (PRIVATE)

#pragma mark Click feedback from displays

- (void) notificationClicked:(NSNotification *)notification {
	GrowlApplicationNotification *growlNotification = [notification object];
		
	[self growlNotificationDict:[growlNotification dictionaryRepresentation] didCloseViaNotificationClick:YES onLocalMachine:YES];
}

- (void) notificationTimedOut:(NSNotification *)notification {
	GrowlApplicationNotification *growlNotification = [notification object];
	
	[self growlNotificationDict:[growlNotification dictionaryRepresentation] didCloseViaNotificationClick:NO onLocalMachine:YES];
}

@end

@implementation NSString (GrowlNetworkingAdditions)

- (BOOL)Growl_isLikelyDomainName
{
	NSUInteger length = [self length];
	NSString *lowerSelf = [self lowercaseString];
	if (length > 3 &&
		[self rangeOfString:@"." options:NSLiteralSearch].location != NSNotFound) {
		static NSArray *TLD2 = nil;
		static NSArray *TLD3 = nil;
		static NSArray *TLD4 = nil;
		if (!TLD2) {
			TLD2 = [[NSArray arrayWithObjects:@".ac", @".ad", @".ae", @".af", @".ag", @".ai", @".al", @".am", @".an", @".ao", @".aq", @".ar", @".as", @".at", @".au", @".aw", @".az", @".ba", @".bb", @".bd", @".be", @".bf", @".bg", @".bh", @".bi", @".bj", @".bm", @".bn", @".bo", @".br", @".bs", @".bt", @".bv", @".bw", @".by", @".bz", @".ca", @".cc", @".cd", @".cf", @".cg", @".ch", @".ci", @".ck", @".cl", @".cm", @".cn", @".co", @".cr", @".cu", @".cv", @".cx", @".cy", @".cz", @".de", @".dj", @".dk", @".dm", @".do", @".dz", @".ec", @".ee", @".eg", @".eh", @".er", @".es", @".et", @".eu", @".fi", @".fj", @".fk", @".fm", @".fo", @".fr", @".ga", @".gd", @".ge", @".gf", @".gg", @".gh", @".gi", @".gl", @".gm", @".gn", @".gp", @".gq", @".gr", @".gs", @".gt", @".gu", @".gw", @".gy", @".hk", @".hm", @".hn", @".hr", @".ht", @".hu", @".id", @".ie", @".il", @".im", @".in", @".io", @".iq", @".ir", @".is", @".it", @".je", @".jm", @".jo", @".jp", @".ke", @".kg", @".kh", @".ki", @".km", @".kn", @".kp", @".kr", @".kw", @".ky", @".kz", @".la", @".lb", @".lc", @".li", @".lk", @".lr", @".ls", @".lt", @".lu", @".lv", @".ly", @".ma", @".mc", @".md", @".me", @".mg", @".mh", @".mk", @".ml", @".mm", @".mn", @".mo", @".mp", @".mq", @".mr", @".ms", @".mt", @".mu", @".mv", @".mw", @".mx", @".my", @".mz", @".na", @".nc", @".ne", @".nf", @".ng", @".ni", @".nl", @".no", @".np", @".nr", @".nu", @".nz", @".om", @".pa", @".pe", @".pf", @".pg", @".ph", @".pk", @".pl", @".pm", @".pn", @".pr", @".ps", @".pt", @".pw", @".py", @".qa", @".re", @".ro", @".ru", @".rw", @".sa", @".sb", @".sc", @".sd", @".se", @".sg", @".sh", @".si", @".sj", @".sk", @".sl", @".sm", @".sn", @".so", @".sr", @".st", @".sv", @".sy", @".sz", @".tc", @".td", @".tf", @".tg", @".th", @".tj", @".tk", @".tm", @".tn", @".to", @".tp", @".tr", @".tt", @".tv", @".tw", @".tz", @".ua", @".ug", @".uk", @".um", @".us", @".uy", @".uz", @".va", @".vc", @".ve", @".vg", @".vi", @".vn", @".vu", @".wf", @".ws", @".ye", @".yt", @".yu", @".za", @".zm", @".zw", nil] retain];
			TLD3 = [[NSArray arrayWithObjects:@".com",@".edu",@".gov",@".int",@".mil",@".net",@".org",@".biz",@".",@".pro",@".cat", nil] retain];
			TLD4 = [[NSArray arrayWithObjects:@".info",@".aero",@".coop",@".mobi",@".jobs",@".arpa", nil] retain];
		}
		if ([TLD2 containsObject:[lowerSelf substringFromIndex:length-3]] ||
			(length > 4 && [TLD3 containsObject:[lowerSelf substringFromIndex:length-4]]) ||
			(length > 5 && [TLD4 containsObject:[lowerSelf substringFromIndex:length-5]]) ||
			[lowerSelf hasSuffix:@".museum"] || [lowerSelf hasSuffix:@".travel"]) {
			return YES;
		} else {
			return NO;
		}
	}
	
	return NO;
}

- (BOOL)Growl_isLikelyIPAddress
{
	/* TODO: Use inet_pton(), which will handle ipv4 and ipv6 */
   if(inet_pton(AF_INET, [self cStringUsingEncoding:NSUTF8StringEncoding], nil) == 1 ||
      inet_pton(AF_INET6, [self cStringUsingEncoding:NSUTF8StringEncoding], nil) == 1)
      return YES;
   else
      return NO;
	//return ([[self componentsSeparatedByString:@"."] count] == 4);
}

@end
