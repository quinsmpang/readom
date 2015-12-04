//
//  TKHTTPRequest.m
//  Created by Devin Ross on 9/24/11.
//
/*
 
 tapku.com || https://github.com/devinross/tapkulibrary
 
 Permission is hereby granted, free of charge, to any person
 obtaining a copy of this software and associated documentation
 files (the "Software"), to deal in the Software without
 restriction, including without limitation the rights to use,
 copy, modify, merge, publish, distribute, sublicense, and/or sell
 copies of the Software, and to permit persons to whom the
 Software is furnished to do so, subject to the following
 conditions:
 
 The above copyright notice and this permission notice shall be
 included in all copies or substantial portions of the Software.
 
 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
 EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
 OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
 NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
 HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
 WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
 OTHER DEALINGS IN THE SOFTWARE.
 
 */

#import "TKHTTPRequest.h"
#import "TKNetworkQueue.h"

typedef enum TKOperationState {
    TKOperationStateInited = 1, 
    TKOperationStateExecuting = 2, 
    TKOperationStateFinished = 3
} TKOperationState;


static BOOL shouldUpdateNetworkActivityIndicator = YES;
static unsigned int runningRequestCount = 0;
NSString* const TKNetworkRequestErrorDomain = @"TKHTTPRequestErrorDomain";
static inline NSString * TKKeyPathFromOperationState(TKOperationState state) {
    switch (state) {
        case TKOperationStateInited:
            return @"isReady";
        case TKOperationStateExecuting:
            return @"isExecuting";
        case TKOperationStateFinished:
            return @"isFinished";
        default:
            return @"state";
    }
}

#pragma mark -
@interface TKHTTPRequest ()

- (void) _completeRequest;
- (void) _requestFinished;

- (BOOL) removeTemporaryFile;
- (BOOL) removeDesitinationFile;
+ (BOOL) removeFileAtPath:(NSString *)path error:(NSError **)err;

- (void) _decreaseNetworkActivity;
- (void) _increaseNetworkActivity;

@property (assign, nonatomic) TKOperationState state;
@property (readwrite, nonatomic, assign, getter = isCancelled) BOOL cancelled;

@property (nonatomic,strong) NSURLConnection *connection;
@property (nonatomic,strong) NSMutableData *data;
@property (nonatomic,strong) NSFileHandle *fileHandler; 	// Used for writing data to a file when downloadDestinationPath is set

@end


#pragma mark - 

@implementation TKHTTPRequest

@synthesize URL,tag,showNetworkActivity;
@synthesize temporaryFileDownloadPath,downloadDestinationPath;
@synthesize didStartSelector,didReceiveResponseSelector,didFinishSelector,didFailSelector,delegate;
@synthesize progressDelegate;
@synthesize statusCode,responseHeaders,error;
@synthesize cancelled=_cancelled,state = _state;
@synthesize URLRequest;
@synthesize connection,data,fileHandler;
@synthesize totalExpectedImageSize = _totalExpectedImageSize, receivedDataBytes = _receivedDataBytes, currentReceivedDataBytes = _currentReceivedDataBytes;


#pragma mark - Threading
+ (void) networkRequestThreadEntryPoint:(id)__unused object {
    do {
		@autoreleasepool{
			[[NSRunLoop currentRunLoop] run];
		}
    } while (YES);
}
+ (NSThread *) networkRequestThread {
    static NSThread *_networkRequestThread = nil;
    static dispatch_once_t oncePredicate;
    
    dispatch_once(&oncePredicate, ^{
        _networkRequestThread = [[NSThread alloc] initWithTarget:self selector:@selector(networkRequestThreadEntryPoint:) object:nil];
        [_networkRequestThread start];
    });
    
    return _networkRequestThread;
}


#pragma mark - Init & Dealloc
+ (TKHTTPRequest*) requestWithURL:(NSURL*)URL{
	return [[self alloc] initWithURL:URL];
}
- (id) initWithURL:(NSURL*)url{
	if(!(self=[super init])) return nil;
	
	
	self.URL = url;
	self.showNetworkActivity = YES;
	self.state = TKOperationStateInited;

	
	return self;
}

+ (TKHTTPRequest*) requestWithURLRequest:(NSURLRequest*)request{
	return [[self alloc] initWithURLRequest:request];
}
- (id) initWithURLRequest:(NSURLRequest*)request{
	if(!(self=[super init])) return nil;
	
	self.URLRequest = request;
	self.showNetworkActivity = YES;
	self.state = TKOperationStateInited;
	
	return self;
}

- (void) startAsynchronous{
	[[TKNetworkQueue sharedNetworkQueue] addOperation:self];
}


#pragma mark -
- (void) start{

    
	if(![self isReady]) return;
	
	self.state = TKOperationStateExecuting;
	[self performSelector:@selector(_startOnNetworkThread) onThread:[[self class] networkRequestThread] withObject:nil waitUntilDone:NO];
}
- (void) _startOnNetworkThread{
	
	if([self isCancelled]) { 
		[self _completeRequest]; 
		return; 
	}
	
	_receivedDataBytes = 0;
    _currentReceivedDataBytes = 0;
	_totalExpectedImageSize = 0;
	
	if(self.URLRequest){
		connection = [[NSURLConnection alloc] initWithRequest:self.URLRequest delegate:self];
    }else{
		connection = [[NSURLConnection alloc] initWithRequest:[NSURLRequest requestWithURL:self.URL] delegate:self];
    }
	
	
	[self.connection start];
	
	if (self && delegate && self.delegate) {
        [self performSelectorOnMainThread:@selector(_requestStarted) withObject:nil waitUntilDone:[NSThread isMainThread]];
    }
}
- (void) _requestStarted{    
	if(self.delegate && [self.delegate respondsToSelector:didStartSelector])
		[self.delegate performSelector:self.didStartSelector withObject:self];
	
#if NS_BLOCKS_AVAILABLE
	if(startedBlock) startedBlock();
#endif
}

- (void) stopRequest{
    [self cancel];
}

- (void) _completeRequest{

	if(self.connection){
		[self.connection cancel];
		self.connection = nil;
	}
	
	
	self.state = TKOperationStateFinished;
	
	if(!self.error && self.temporaryFileDownloadPath){
		
		
		NSError *moveError = nil;

		[self.fileHandler closeFile];
		
		
		if (![[self class] removeFileAtPath:self.downloadDestinationPath error:&moveError])  self.error = moveError;

		if (!moveError) {
			
			[[NSFileManager defaultManager] moveItemAtPath:self.temporaryFileDownloadPath toPath:self.downloadDestinationPath error:&moveError];
			
			if (moveError){
				NSString *str = [NSString stringWithFormat:@"Failed to move file from '%@' to '%@'",self.temporaryFileDownloadPath,self.downloadDestinationPath];
				NSDictionary *userInfo = [NSDictionary dictionaryWithObjectsAndKeys:str,NSLocalizedDescriptionKey,moveError,NSUnderlyingErrorKey,nil];
				self.error = [NSError errorWithDomain:TKNetworkRequestErrorDomain code:TKFileManagementError userInfo:userInfo];
			}
		}
		
	}
	
	SEL mainThreadRoute;
	
	if(self.error)
		mainThreadRoute = @selector(_requestFailed);
	else
		mainThreadRoute = @selector(_requestFinished);

	[self performSelectorOnMainThread:mainThreadRoute withObject:nil waitUntilDone:[NSThread isMainThread]];

	
}

- (void) _requestFinished{
	if(self.delegate && [self.delegate respondsToSelector:self.didFinishSelector])
		[self.delegate performSelector:self.didFinishSelector withObject:self];

#if NS_BLOCKS_AVAILABLE
	if(completionBlock) completionBlock();
#endif
	
}

- (void) _requestFailed{
	if(self.delegate && [self.delegate respondsToSelector:didFailSelector]) [self.delegate performSelector:didFailSelector withObject:self];
#if NS_BLOCKS_AVAILABLE
	if(failureBlock) failureBlock();
#endif
}
- (void) failWithError:(NSError *)theError{
	
	self.state = TKOperationStateFinished;
	self.error = theError;
	
}



#pragma mark - Delegate Methods for NSURLConnection
- (BOOL)connection:(NSURLConnection *)conn canAuthenticateAgainstProtectionSpace:(NSURLProtectionSpace *)protectionSpace
{
    //InfoLog(@"authenticate method:%@",protectionSpace.authenticationMethod);
    return [protectionSpace.authenticationMethod isEqualToString:
            NSURLAuthenticationMethodServerTrust];
}

- (void)connection:(NSURLConnection *)conn didReceiveAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge
{

    NSURLCredential *   credential;
    
    NSURLProtectionSpace *  protectionSpace;
    SecTrustRef             trust;
//    NSString *              host;
//    SecCertificateRef       serverCert;
    assert(challenge !=nil);
    protectionSpace = [challenge protectionSpace];
    assert(protectionSpace != nil);
    
    trust = [protectionSpace serverTrust];
    assert(trust != NULL);
    
    credential = [NSURLCredential credentialForTrust:trust];
    assert(credential != nil);
    
//    host = [[challenge protectionSpace] host];
    
//    if (SecTrustGetCertificateCount(trust) > 0) {
//        serverCert = SecTrustGetCertificateAtIndex(trust, 0);
//    } else {
//        serverCert = NULL;
//    }
    
    
    [[challenge sender] useCredential:credential forAuthenticationChallenge:challenge];
}

- (void) connection:(NSURLConnection*)connection didFailWithError:(NSError*)e{
	

	if(self.connection){
		[self.connection cancel];
		self.connection = nil;
	}
	

	if(self.temporaryFileDownloadPath) [self removeTemporaryFile];

	self.data=nil;
	[self failWithError:e];
	
    if (self && delegate && self.delegate) {
        [self performSelectorOnMainThread:@selector(_requestFailed) withObject:nil waitUntilDone:[NSThread isMainThread]];
    }
}
- (void) connection:(NSURLConnection *)connection didReceiveData:(NSData *)d{
	
	
	_receivedDataBytes += (NSInteger) [d length];
    _currentReceivedDataBytes = (NSInteger) [d length];
	
	if(self.downloadDestinationPath){
		
		if(!self.fileHandler){
			
			if(!self.temporaryFileDownloadPath){
				NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSProcessInfo processInfo] globallyUniqueString]];
				self.temporaryFileDownloadPath = tmp;
			}
			
			
			[self removeTemporaryFile];
			[[NSFileManager defaultManager] createFileAtPath:self.temporaryFileDownloadPath contents:nil attributes:nil];
			self.fileHandler = [NSFileHandle fileHandleForWritingAtPath:self.temporaryFileDownloadPath];
			
			if(self.fileHandler==nil) {
				NSString *str = [NSString stringWithFormat:@"Failed to create file from '%@'",self.temporaryFileDownloadPath];
				NSDictionary *userInfo = [NSDictionary dictionaryWithObjectsAndKeys:str,NSLocalizedDescriptionKey,nil];
				self.error = [NSError errorWithDomain:TKNetworkRequestErrorDomain code:TKFileManagementError userInfo:userInfo];
				[self _completeRequest];
			}
				
		}
		
		
		[self.fileHandler writeData:d];

		
	}else
		[data appendData:d];
	
	
	
	
	
	if(self.progressDelegate){
		dispatch_async(dispatch_get_main_queue(), ^{
			if([self.progressDelegate respondsToSelector:@selector(request:didReceiveTotalBytes:ofExpectedBytes:)])
				[self.progressDelegate request:self didReceiveTotalBytes:_receivedDataBytes ofExpectedBytes:_totalExpectedImageSize];
		});
	}
	
	
}
- (void) connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response{

	
	NSHTTPURLResponse* httpResponse = (NSHTTPURLResponse*)response;
	self.statusCode = [httpResponse statusCode];
	self.responseHeaders = [httpResponse allHeaderFields];
	
	
	if(self.statusCode == 200) {
		_totalExpectedImageSize = (double)response.expectedContentLength;
		NSUInteger contentSize = [httpResponse expectedContentLength] > 0 ? [httpResponse expectedContentLength] : 0;
		data = [[NSMutableData alloc] initWithCapacity:contentSize];
        if(self.delegate && [self.delegate respondsToSelector:didReceiveResponseSelector])
            [self.delegate performSelector:self.didReceiveResponseSelector withObject:self];
	} else {
		NSString* statusError  = [NSString stringWithFormat:NSLocalizedString(@"HTTP Error: %ld", nil), self.statusCode];
		NSDictionary* userInfo = [NSDictionary dictionaryWithObject:statusError forKey:NSLocalizedDescriptionKey];
		error = [[NSError alloc] initWithDomain:TKNetworkRequestErrorDomain code:self.statusCode userInfo:userInfo];
		[self _completeRequest];
	}
	
}
- (void) connectionDidFinishLoading:(NSURLConnection *)connection{
	[self _completeRequest];
}



#pragma mark - Blocks
#if NS_BLOCKS_AVAILABLE
- (void) setStartedBlock:(TKBasicBlock)aStartedBlock{
	startedBlock = [aStartedBlock copy];
}
- (void) setCompletionBlock:(TKBasicBlock)aCompletionBlock{
	completionBlock = [aCompletionBlock copy];
}
- (void) setFailedBlock:(TKBasicBlock)aFailedBlock{
	failureBlock = [aFailedBlock copy];
}
#endif



#pragma mark -
#pragma mark Properties
- (BOOL) isConcurrent{
	return YES;
}
- (BOOL) isReady{
	return self.state == TKOperationStateInited;
}
- (BOOL) isExecuting{
	return self.state == TKOperationStateExecuting;
}
- (BOOL) isFinished{
	return self.state == TKOperationStateFinished;
}
- (NSData *) responseData{	
	return [NSData dataWithData:self.data];
}


- (BOOL) shouldTransitionToState:(TKOperationState)state {    
    switch (self.state) {
        case TKOperationStateInited:
            switch (state) {
                case TKOperationStateExecuting:
                    return YES;
                default:
                    return NO;
            }
        case TKOperationStateExecuting:
            switch (state) {
                case TKOperationStateFinished:
                    return YES;
                default:
                    return NO;
            }
        case TKOperationStateFinished:
            return NO;
        default:
            return YES;
    }
}
- (void) setState:(TKOperationState)state {
	
    if (![self shouldTransitionToState:state]) return;
	
	
	if(state == TKOperationStateExecuting)
		[self _increaseNetworkActivity];
	else if(state == TKOperationStateFinished && self.state == TKOperationStateExecuting)
		[self _decreaseNetworkActivity];
    
    
    NSString *oldStateKey = TKKeyPathFromOperationState(self.state);
    NSString *newStateKey = TKKeyPathFromOperationState(state);
	
    [self willChangeValueForKey:newStateKey];
    [self willChangeValueForKey:oldStateKey];
    _state = state;
    [self didChangeValueForKey:oldStateKey];
    [self didChangeValueForKey:newStateKey];
    
	
}


- (void) setCancelled:(BOOL)cancelled {
    [self willChangeValueForKey:@"isCancelled"];
    _cancelled = cancelled;
    [self didChangeValueForKey:@"isCancelled"];
    
    if ([self isCancelled]) self.state = TKOperationStateFinished;
}
- (void) cancel {
    if([self isFinished]) return;
        
    [super cancel];
    self.cancelled = YES;
	
	[self performSelector:@selector(_cancelOnRequestThread) onThread:[[self class] networkRequestThread] withObject:nil waitUntilDone:NO];    
	
}
- (void) _cancelOnRequestThread{
	if(self.connection){
		[self.connection cancel];
//		self.connection=nil;
	}
}


#pragma mark -
#pragma mark Network Activity
+ (BOOL) isNetworkInUse{
	return runningRequestCount > 0;
}
+ (void) setShouldUpdateNetworkActivityIndicator:(BOOL)shouldUpdate{
	shouldUpdateNetworkActivityIndicator = shouldUpdate;
}
+ (void) showNetworkActivityIndicator{
#if TARGET_OS_IPHONE
	if (shouldUpdateNetworkActivityIndicator) 
		[[UIApplication sharedApplication] setNetworkActivityIndicatorVisible:YES];
#endif
}
+ (void) hideNetworkActivityIndicator{
#if TARGET_OS_IPHONE
	[[UIApplication sharedApplication] setNetworkActivityIndicatorVisible:NO];	
#endif
}
+ (void) hideNetworkActivityIndicatorAfterDelay{
	[self performSelector:@selector(hideNetworkActivityIndicatorIfNeeeded) withObject:nil afterDelay:0.5];
}
+ (void) hideNetworkActivityIndicatorIfNeeeded{
	if (runningRequestCount == 0) {
		[self hideNetworkActivityIndicator];
	}
}
- (void) _decreaseNetworkActivity{
	if(self.showNetworkActivity){
		runningRequestCount--;
		if (shouldUpdateNetworkActivityIndicator && runningRequestCount == 0) 
			[[self class] performSelectorOnMainThread:@selector(hideNetworkActivityIndicatorAfterDelay) withObject:nil waitUntilDone:[NSThread isMainThread]];
		

	}
}
- (void) _increaseNetworkActivity{
	
	
	
	if(self.showNetworkActivity){
		runningRequestCount++;
		if (shouldUpdateNetworkActivityIndicator) 
			[[self class] performSelectorOnMainThread:@selector(showNetworkActivityIndicator) withObject:nil waitUntilDone:[NSThread isMainThread]];
	}
}


+ (BOOL) removeFileAtPath:(NSString *)path error:(NSError **)err{
	NSFileManager *fileManager = [[NSFileManager alloc] init];
	
	if ([fileManager fileExistsAtPath:path]) {
		NSError *removeError = nil;
		[fileManager removeItemAtPath:path error:&removeError];
		if (removeError) {
			if (err) {
				*err = [NSError errorWithDomain:TKNetworkRequestErrorDomain code:TKFileManagementError userInfo:[NSDictionary dictionaryWithObjectsAndKeys:[NSString stringWithFormat:@"Failed to delete file at path '%@'",path],NSLocalizedDescriptionKey,removeError,NSUnderlyingErrorKey,nil]];
			}
			return NO;
		}
	}
    
	return YES;
}
- (BOOL) removeTemporaryFile{
	if(!self.temporaryFileDownloadPath) return YES;
	NSError *err = nil;
	[[self class] removeFileAtPath:self.temporaryFileDownloadPath error:&err];
	return (!err);
}
- (BOOL) removeDesitinationFile{
	if(!self.downloadDestinationPath) return YES;

	NSError *err = nil;
	[[self class] removeFileAtPath:self.downloadDestinationPath error:&err];
	
	return (!err);
}

@end