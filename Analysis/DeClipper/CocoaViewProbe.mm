#import <Cocoa/Cocoa.h>
#import <AudioToolbox/AudioToolbox.h>
#import <AudioUnit/AUCocoaUIView.h>
int main(int argc,char**argv){ @autoreleasepool {
[NSApplication sharedApplication];
AudioComponentDescription desc{'aufx','DcF5','Accu',0,0};
AudioComponent c=AudioComponentFindNext(nullptr,&desc); AudioUnit au=nullptr;
if(!c || AudioComponentInstanceNew(c,&au)) return 1;
UInt32 size=0; Boolean w=false;
OSStatus e=AudioUnitGetPropertyInfo(au,kAudioUnitProperty_CocoaUI,kAudioUnitScope_Global,0,&size,&w);if(e)return 2;
auto* info=(AudioUnitCocoaViewInfo*)calloc(1,size);e=AudioUnitGetProperty(au,kAudioUnitProperty_CocoaUI,kAudioUnitScope_Global,0,info,&size);if(e)return 3;
NSBundle* b=[NSBundle bundleWithURL:(__bridge NSURL*)info->mCocoaAUViewBundleLocation]; [b load];
Class cl=[b classNamed:(__bridge NSString*)info->mCocoaAUViewClass[0]];
id<AUCocoaUIBase> factory=[[cl alloc]init]; NSView* view=[factory uiViewForAudioUnit:au withSize:NSMakeSize(300,420)];if(!view)return 4;
NSRect rect=[view bounds];NSWindow* window=[[NSWindow alloc]initWithContentRect:rect styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
[window setContentView:view];[view layoutSubtreeIfNeeded];[view display];
NSDate* until=[NSDate dateWithTimeIntervalSinceNow:0.5];while([until timeIntervalSinceNow]>0){[[NSRunLoop currentRunLoop]runMode:NSDefaultRunLoopMode beforeDate:until];}
NSBitmapImageRep* rep=[view bitmapImageRepForCachingDisplayInRect:rect];[view cacheDisplayInRect:rect toBitmapImageRep:rep];
NSData* png=[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];[png writeToFile:[NSString stringWithUTF8String:argv[1]] atomically:YES];
printf("{\"width\":%.0f,\"height\":%.0f,\"class\":\"%s\"}\n",rect.size.width,rect.size.height,NSStringFromClass([view class]).UTF8String);
[window setContentView:nil]; AudioComponentInstanceDispose(au);return 0;
}}
