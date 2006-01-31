/*

BSD License

Copyright (c) 2005, Keith Anderson
All rights reserved.

Redistribution and use in source and binary forms, with or without modification,
are permitted provided that the following conditions are met:

*	Redistributions of source code must retain the above copyright notice,
	this list of conditions and the following disclaimer.
*	Redistributions in binary form must reproduce the above copyright notice,
	this list of conditions and the following disclaimer in the documentation
	and/or other materials provided with the distribution.
*	Neither the name of keeto.net or Keith Anderson nor the names of its
	contributors may be used to endorse or promote products derived
	from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS
BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY,
OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT
OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.


*/

#import "KNArticle.h"

#import "Library.h"
#import "Library+Utility.h"
#import "Prefs.h"
#import "NSDate+KNExtras.h"


@implementation KNArticle

-(id)init{
	if( (self = [super init]) ){
		guid = [[NSString stringWithString: [super key]] retain];
		feedName = [[NSString string] retain];
		status = [[NSString stringWithString: StatusUnread] retain];
		link = [[NSString string] retain];
		sourceURL = [[NSString string] retain];
		commentsURL = [[NSString string] retain];
		author = [[NSString string] retain];
		date = [[NSDate date] retain];
		category = [[NSString string] retain];
		summary = [[NSString string] retain];
		content = [[NSString string] retain];
		titleHTML = [[NSString string] retain];
		title = [[NSAttributedString alloc] init];
		isOnServer = NO;
		isSuppressed = NO;
	}
	return self;
}

-(id)initWithCoder:(NSCoder *)aCoder{
	if( (self = [super initWithCoder: aCoder]) ){
	
		guid = [aCoder decodeObjectForKey: ArticleGuid];
		if( !guid ){ 
			guid = [NSString stringWithString: [super key]];
		}
		[guid retain];
		
		feedName = [aCoder decodeObjectForKey: ArticleFeedName];
		if( ! feedName ){
			feedName = [NSString stringWithString: guid];
		}
		[feedName retain];
		
		status = [aCoder decodeObjectForKey: ArticleStatus];
		if( ! status ){
			status = [NSString stringWithString: StatusUnread];
		}
		[status retain];
		
		link = [aCoder decodeObjectForKey: ArticleLink];
		if( ! link ){
			link = [NSString string];
		}
		[link retain];
		
		sourceURL = [aCoder decodeObjectForKey: ArticleSourceURL];
		if( ! sourceURL ){
			sourceURL = [NSString string];
		}
		[sourceURL retain];
		
		commentsURL = [aCoder decodeObjectForKey: ArticleCommentsURL];
		if( ! commentsURL ){
			commentsURL = [NSString string];
		}
		[commentsURL retain];
		
		author = [aCoder decodeObjectForKey: ArticleAuthor];
		if( ! author ){
			author = [NSString string];
		}
		[author retain];
		
		date = [aCoder decodeObjectForKey: ArticleDate];
		if( ! date ){
			date = [NSDate date];
		}
		[date retain];
		
		category = [aCoder decodeObjectForKey: ArticleCategory];
		if( ! category ){
			category = [NSString string];
		}
		[category retain];
		
		summary = [aCoder decodeObjectForKey: ArticleSummary];
		if( ! summary ){
			summary = [NSString string];
		}
		[summary retain];
		
		content = [aCoder decodeObjectForKey: ArticleContent];
		if( ! content ){
			content = [NSString string];
		}
		[content retain];
		
		title = [aCoder decodeObjectForKey: ArticleTitle];
		if( ! title ){
			title = [NSString string];
		}
		[title retain];
		
		titleHTML = [aCoder decodeObjectForKey: ArticleTitleHTML];
		if( ! titleHTML ){
			titleHTML = [NSString string];
		}
		[titleHTML retain];
		
		NSNumber * storedNumber;
		
		storedNumber = [aCoder decodeObjectForKey: ArticleIsOnServer];
		isOnServer = storedNumber ? [storedNumber boolValue] : TRUE;
		
		storedNumber = [aCoder decodeObjectForKey: ArticleIsSuppressed];
		isSuppressed = storedNumber ? [storedNumber boolValue] : FALSE;
	}
	return self;
}

-(void)encodeWithCoder:(NSCoder *)aCoder{
	[super encodeWithCoder: aCoder];
	
	[aCoder encodeObject: guid forKey: ArticleGuid];
	[aCoder encodeObject: feedName forKey: ArticleFeedName];
	[aCoder encodeObject: status forKey: ArticleStatus];
	[aCoder encodeObject: link forKey: ArticleLink];
	[aCoder encodeObject: sourceURL forKey: ArticleSourceURL];
	[aCoder encodeObject: commentsURL forKey: ArticleCommentsURL];
	[aCoder encodeObject: author forKey: ArticleAuthor];
	[aCoder encodeObject: date forKey: ArticleDate];
	[aCoder encodeObject: category forKey: ArticleCategory];
	[aCoder encodeObject: summary forKey: ArticleSummary];
	[aCoder encodeObject: content forKey: ArticleContent];
	[aCoder encodeObject: titleHTML forKey: ArticleTitleHTML];
	[aCoder encodeObject: title forKey: ArticleTitle];
	[aCoder encodeObject: [NSNumber numberWithBool: isOnServer] forKey: ArticleIsOnServer];
	[aCoder encodeObject: [NSNumber numberWithBool: isSuppressed] forKey: ArticleIsSuppressed];
}

-(void)dealloc{	
	[guid release];
	[feedName release];
	[status release];
	[link release];
	[sourceURL release];
	[commentsURL release];
	[author release];
	[date release];
	[category release];
	[summary release];
	[content release];
	[titleHTML release];
	[title release];
	
	[super dealloc];
}

-(NSComparisonResult)compareByDate:(KNArticle *)article{
	return [[self date] compare: [article date]];
}

-(BOOL)canHaveChildren{ return NO; }

#pragma mark -
#pragma mark Update Support

-(void)willUpdate{
	isCacheValid = YES;
}

-(void)didUpdate{
	if( ! isCacheValid ){
		[LIB articleIsStale: self];
	}
}

#pragma mark -
#pragma mark Properties

-(void)_updatedIfOld:(id)oldValue changed:(id)newValue{
	if( ! [oldValue isEqual: newValue] ){
		[self setStatus: StatusUpdated];
		[LIB makeDirty];
		isCacheValid = NO;
	}
}

-(NSString *)type{
	return FeedItemTypeArticle;
}


-(unsigned)unreadCount{
	return ([[self status] isEqualToString: StatusUnread] ? 1 : 0);
}

-(NSString *)previewCachePath{
	return [[[(KNFeed *)parent previewCachePath] stringByAppendingPathComponent: [self key]] stringByAppendingPathExtension:@".html"];
}

-(void)setGuid:(NSString *)aGuid{
	if( ! aGuid ){ ItemThrow(@"Attempt to set nil guid in Article"); }
	
	[guid autorelease];
	guid = [aGuid retain];
	[LIB makeDirty];
}

-(NSString *)guid{
	return guid;
}

-(void)setParent:(KNItem *)anItem{
	[super setParent: anItem];
	
	if( parent && [[parent type] isEqualToString: FeedItemTypeFeed] ){
		[feedName autorelease];
		feedName = [[parent name] retain];
		[LIB makeDirty];
	}
	
}

-(NSString *)feedName{
	return feedName;
}

-(void)setName:(NSString *)aName{
	[self setTitle: aName];
}

-(NSString *)name{
	return [self title];
}

-(void)setTitleHTML:(NSString *)aTitleHTML{
	if( ! aTitleHTML ){ ItemThrow(@"Attempt to set nil titleHTML in Article"); }
	
	[titleHTML autorelease];
	titleHTML = [aTitleHTML retain];
	
	[self setTitle: titleHTML];
}

-(NSString *)titleHTML{
	return titleHTML;
}

-(void)setTitle:(NSString *)aTitle{
	if( ! aTitle ){ ItemThrow(@"Attempt to set nil title in Article"); }
	
	[self _updatedIfOld: title changed: aTitle];
	
	[title autorelease];
	title = [aTitle retain];
}

-(NSString *)title{
	NSAttributedString *	renderedString = [[[NSAttributedString alloc] initWithHTML: [title  dataUsingEncoding:[title fastestEncoding]] documentAttributes: nil] autorelease];
	NSString *				collapsedTitle = [NSString stringWithString: [renderedString string]];
	
	return collapsedTitle;
}

-(void)setStatus:(NSString *)aStatus{
	if( [aStatus isEqualToString: StatusUnread] ||
		[aStatus isEqualToString: StatusUpdated] ||
		[aStatus isEqualToString: StatusRead]
	){
		if( [aStatus isEqualToString: StatusUpdated] ){
			if( [status isEqualToString: StatusRead] ){
				[status autorelease];
				status = [aStatus retain];
				[LIB makeDirty];
			}
		}else if(! [aStatus isEqualToString: status] ){
			[status autorelease];
			status = [aStatus retain];
			[LIB makeDirty];
		}
	}else{
		ItemThrow(@"Attempt to set unknown status in Article");
	}
}

-(NSString *)status{
	return status;
}

-(void)setLink:(NSString *)aLink{
	if( ! aLink ){ ItemThrow(@"Attempt to set nil link in Article"); }
	
	[self _updatedIfOld: link changed: aLink];
	
	[link autorelease];
	link = [aLink retain];
}

-(NSString *)link{
	return link;
}

-(void)setSourceURL:(NSString *)aSourceURL{
	if( ! aSourceURL ){ ItemThrow(@"Attempt to set nil source URL in Article"); }
	
	[self _updatedIfOld: sourceURL changed: aSourceURL];
	
	[sourceURL autorelease];
	sourceURL = [aSourceURL retain];
}

-(NSString *)sourceURL{
	return sourceURL;
}

-(void)setCommentsURL:(NSString *)aCommentURL{
	if( ! aCommentURL ){ ItemThrow(@"Attempt to set nil comment URL in Article"); }
	
	[self _updatedIfOld: commentsURL changed: aCommentURL];
	
	[commentsURL autorelease];
	commentsURL = [aCommentURL retain];
}

-(NSString *)commentsURL{
	return commentsURL;
}

-(void)setAuthor:(NSString *)anAuthor{
	if( ! anAuthor ){ ItemThrow(@"Attempt to set nil author in Article"); }
	
	[self _updatedIfOld: author changed: anAuthor];
	
	[author autorelease];
	author = [anAuthor retain];
}

-(NSString *)author{
	return author;
}

-(void)setDate:(NSDate *)aDate{
	if( ! aDate ){ ItemThrow(@"Attempt to set nil date in Article"); }
	
	[self _updatedIfOld: date changed: aDate];
	
	[date autorelease];
	date = [aDate retain];
}

-(NSDate *)date{
	return date;
}

-(void)setCategory:(NSString *)aCategory{
	if( ! aCategory ){ ItemThrow(@"Attempt to set nil category in Article"); }
	
	[self _updatedIfOld: category changed: aCategory];
	
	[category autorelease];
	category = [aCategory retain];
}

-(NSString *)category{
	return category;
}

-(void)setSummary:(NSString *)aSummary{
	if( ! aSummary ){ ItemThrow(@"Attempt to set nil summary in Article"); }
	
	[self _updatedIfOld: summary changed: aSummary];
	
	[summary autorelease];
	summary = [aSummary retain];
}

-(NSString *)summary{
	return summary;
}

-(void)setContent:(NSString *)aContent{
	if( ! aContent ){ ItemThrow(@"Attempt to set nil content in Article"); }
	
	if( ![aContent isEqualToString: content] ){
		[self setStatus: StatusUpdated];
		[content autorelease];
		content = [aContent retain];
	}
}

-(NSString *)content{
	return content;
}

-(void)setIsOnServer:(BOOL)onServerFlag{
	isOnServer = onServerFlag;
}

-(BOOL)isOnServer{
	return isOnServer;
}

-(void)setIsSuppressed:(BOOL)suppressionFlag{
	isSuppressed = suppressionFlag;
	[self setStatus: StatusRead];
}

-(BOOL)isSuppressed{
	return isSuppressed;
}

#pragma mark -
#pragma mark Preview Support

-(void)generateCache:(id)sender{
#pragma unused( sender )
	NSMutableString *			displayedHTML = [NSMutableString string];
	NSString *                  dateOutput = [NSString string];
	
	//KNDebug(@"ARTICLE: Generating article cache. font size is %d", (int) [PREFS articleFontSize]);
	
	[displayedHTML appendFormat:@"<html><head><base href=\"%@\"/><body>", [self link]];
	[displayedHTML appendFormat:@"<style>.feed_label{font-size:9pt;font-weight:bold;}</style>"];
	[displayedHTML appendFormat:@"<style>.feed_header{font-size:9pt; padding-left:5px;}</style>"];
	[displayedHTML appendFormat:@"<style>body,td{font-size:%dpt; font-family:%@;}</style>", (int)[PREFS articleFontSize], [PREFS articleFontName]];
	[displayedHTML appendFormat:@"<table cellpadding=\"0\" cellspacing=\"0\">"];
	[displayedHTML appendFormat:@"<tr><td align=\"right\" valign=\"top\" class=\"feed_label\">Feed:</td>"];
	[displayedHTML appendFormat:@"<td valign=\"top\" class=\"feed_header\"><a title=\"Open feed in default browser\" href=\"%@\">%@</a></td></tr>", [(KNFeed *)[self parent] link], [[self parent] name]];
	[displayedHTML appendFormat:@"<tr><td align=\"right\" valign=\"top\" class=\"feed_label\">Title:</td>"];
	[displayedHTML appendFormat:@"<td valign=\"top\" class=\"feed_header\"><a title=\"Open article in default browser\" href=\"%@\">%@</a></td></tr>", [self link], [self titleHTML]];
	
	if( ! [[self author] isEqualToString: @""] ){
		[displayedHTML appendFormat:@"<tr><td align=\"right\" valign=\"top\" class=\"feed_label\">Author:</td>"];
		[displayedHTML appendFormat:@"<td valign=\"top\" class=\"feed_header\"><a title=\"Send email to %@\" href=\"mailto:%@\">%@</a></td></tr>", [self author], [self author], [self author]];
	}
	
	if( ! [[self category] isEqualToString: @""] ){
		[displayedHTML appendFormat:@"<tr><td align=\"right\" valign=\"top\" class=\"feed_label\">Category:</td>"];
		[displayedHTML appendFormat:@"<td valign=\"top\" class=\"feed_header\">%@</td></tr>", [self category]];
	}
		
	if( [self date] ){
		dateOutput = [[self date] naturalString];
	}
	
	if( ! [[self sourceURL] isEqualToString:@""] ){
		[displayedHTML appendFormat:@"<tr><td align=\"right\" valign=\"top\" class=\"feed_label\">Source:</td>"];
		if( [[self sourceURL] isEqualToString:@""] ){
			[displayedHTML appendFormat:@"<td valign=\"top\" class=\"feed_header\">%@</td></tr>", [self sourceURL]];
		}else{
			[displayedHTML appendFormat:@"<td valign=\"top\" class=\"feed_header\"><a href=\"%@\" title=\"Open source %@ in default browser\">%@</a></td></tr>",[self sourceURL], [self sourceURL], [self sourceURL]];
		}
	}
	[displayedHTML appendFormat:@"<tr><td align=\"right\" valign=\"top\" class=\"feed_label\">Date:</td>"];
	[displayedHTML appendFormat:@"<td valign=\"top\" class=\"feed_header\">%@</td></tr>", dateOutput];
	
	
	[displayedHTML appendFormat:@"</table>"];
	[displayedHTML appendFormat:@"<hr>"];
	[displayedHTML appendString: [self content]];
	[displayedHTML appendFormat:@"</body></html>"];
	
	
	BOOL					written = NO;
	NSError *				error;
	NSString *				dest = [self previewCachePath];
	
	if( [self previewCachePath] ){
		if( [displayedHTML respondsToSelector: @selector(writeToFile:atomically:encoding:error:)] ){
			written = [displayedHTML writeToFile: dest atomically: YES encoding: NSUTF8StringEncoding error:&error];
		}else{
			written = [displayedHTML writeToURL: [NSURL fileURLWithPath: dest] atomically: YES];
		}
		
		[self setValue: ArticlePreviewCacheVersion forKeyPath:@"prefs.articlePreviewVersion"];
	}
}

-(void)deleteCache{
	[[NSFileManager defaultManager] removeFileAtPath: [self previewCachePath] handler: nil];
}

@end
