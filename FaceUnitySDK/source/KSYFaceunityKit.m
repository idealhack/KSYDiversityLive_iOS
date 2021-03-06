#import "KSYFaceunityKit.h"
#include <sys/mman.h>
#include <sys/stat.h>
#include "funama.h"
#include "libyuv.h"

#define FLOAT_EQ( f0, f1 ) ( (f0 - f1 < 0.0001)&& (f0 - f1 > -0.0001) )

@interface KSYFaceunityKit (){
    dispatch_queue_t _capDev_q;
    NSLock   *       _quitLock;  // ensure capDev closed before dealloc
    GPUImagePicture *_textPic;
    KSYGPUPicOutput *_pipOut;
}
@property (nonatomic, strong) KSYGPUYUVInput  *yuvInput;
@end

@implementation KSYFaceunityKit

/**
 @abstract   获取SDK版本号
 */
- (NSString*) getKSYVersion {
    if (_streamerBase){
        return [_streamerBase getKSYVersion];
    }
    return @"KSY-i-v0.0.0";
}

/**
 @abstract 初始化方法
 @discussion 创建带有默认参数的 kit，不会打断其他后台的音乐播放
 
 @warning kit只支持单实例推流，构造多个实例会出现异常
 */
- (instancetype) initWithDefaultCfg {
    return [self initInterrupt:NO];
}

/**
 @abstract 初始化方法
 @discussion 创建带有默认参数的 kit，会打断其他后台的音乐播放
 
 @warning kit只支持单实例推流，构造多个实例会出现异常
 */
- (instancetype) initWithInterruptCfg {
    return [self initInterrupt:YES];
}

- (instancetype) initInterrupt:(BOOL) bInter {
    self = [super init];
    _quitLock = [[NSLock alloc] init];
    _capDev_q = dispatch_queue_create( "com.ksyun.capDev_q", DISPATCH_QUEUE_SERIAL);
    // init default property
    _captureState     = KSYCaptureStateIdle;
    _capPreset        = AVCaptureSessionPreset640x480;
    _previewDimension = CGSizeMake(640, 360);
    _streamDimension  = CGSizeMake(640, 360);
    _cameraPosition   = AVCaptureDevicePositionFront;
    _streamerMirrored = NO;
    _previewMirrored  = NO;
    _videoProcessingCallback = nil;
    
    // 图层和音轨的初始化
    _cameraLayer  = 0;
    _logoPicLayer = 1;
    _logoTxtLayer = 2;
    _micTrack = 0;
    _bgmTrack = 1;
    
    /////1. 数据来源 ///////////
    // 采集模块
    _vCapDev = [[KSYGPUCamera alloc] initWithSessionPreset:_capPreset
                                            cameraPosition:_cameraPosition];
    _vCapDev.outputImageOrientation = UIInterfaceOrientationPortrait;
    
    //change nv12torgb
    _pipOut = [[KSYGPUPicOutput alloc]init];
    [_vCapDev addTarget:_pipOut];
    __weak KSYFaceunityKit * kit = self;
    _pipOut.videoProcessingCallback = ^(CVPixelBufferRef pixelBuffer, CMTime timeInfo){
        //add faceunity
        [kit addFaceunity:pixelBuffer time:timeInfo];
        //change rgbaToNV12
        [kit ARGBTONV12:pixelBuffer time:timeInfo];
    };
    //Session模块
    _avAudioSession = [[KSYAVAudioSession alloc] init];
    _avAudioSession.bInterruptOtherAudio = bInter;
    [_avAudioSession setAVAudioSessionOption];
    
    // 创建背景音乐播放模块
    _bgmPlayer = [[KSYBgmPlayer   alloc] init];
    // 音频采集模块
    _aCapDev = [[KSYAUAudioCapture alloc] init];
    
    // 各种图片
    _logoPic = nil;
    _textPic = nil;
    _textLable = [[UILabel alloc] initWithFrame:CGRectMake(0,0, 360, 640)];
    _textLable.textColor = [UIColor whiteColor];
    _textLable.font = [UIFont fontWithName:@"Courier-Bold" size:20.0];
    _textLable.backgroundColor = [UIColor clearColor];
    _textLable.alpha = 0.9;
    
    /////2. 数据出口 ///////////
    // get pic data from gpu filter
    _gpuToStr =[[KSYGPUPicOutput alloc] init];
    _gpuToStr.bCustomOutputSize = YES;
    // 创建 推流模块
    _streamerBase = [[KSYStreamerBase alloc] initWithDefaultCfg];
    // 创建 预览模块, 并放到视图底部
    _preview = [[GPUImageView alloc] init];
    _yuvInput = [[KSYGPUYUVInput alloc]init];
    
    
    ///// 3. 数据处理和通路 ///////////
    ///// 3.1 视频通路 ///////////
    // 核心部件:裁剪滤镜
    CGRect cropR = CGRectMake(0, 0, 1, 1);
    _cropfilter = [[GPUImageCropFilter alloc] initWithCropRegion:cropR];
    // 核心部件:图像处理滤镜
    _filter     = [[KSYGPUBeautifyFilter alloc] init];
    //_filter = [[KSYFUFilter alloc] init];
    // 核心部件:视频叠加混合
    _vMixer = [[KSYGPUPicMixer alloc] init];
    
    // 组装视频通道
    [self setupVideoPath];
    // 初始化图层的位置
    self.logoRect = CGRectMake(0.1 , 0.05, 0, 0.1);
    self.textRect = CGRectMake(0.05, 0.15, 0, 20.0/640);
    
    ///// 3.2 音频通路 ///////////
    // 核心部件:音频叠加混合
    _aMixer = [[KSYAudioMixer alloc]init];
    
    // 组装音频通道
    [self setupAudioPath];
    return self;
}

//------------faceunity-------------//
// Global variables for Faceunity
//  Global flags
static EAGLContext* g_gl_context = nil;   // GL context to draw item
static int g_faceplugin_inited = 0;
static int g_frame_id = 0;
static int g_need_reload_item = 0;
static int g_selected_item = 0;
static volatile int g_reset_camera = 0;
static NSString * path = nil;
//  Predefined items and maintenance
static NSString* g_item_names[] = {@"kitty.bundle", @"fox.bundle", @"evil.bundle", @"eyeballs.bundle", @"mood.bundle", @"tears.bundle", @"rabbit.bundle", @"cat.bundle"};
static const int g_item_num = sizeof(g_item_names) / sizeof(NSString*);
static void* g_mmap_pointers[g_item_num] = {NULL};
static intptr_t g_mmap_sizes[g_item_num] = {0};
static int g_items[1] = {0};
static int n_items = 1;
static NSString* g_item_hints[] = {@"", @"", @"", @"张开嘴巴", @"嘴角向上以及嘴角向下",  @"张开嘴巴", @"", @""};
// Item loading assistant functions
static size_t osal_GetFileSize(int fd){
    struct stat sb;
    sb.st_size = 0;
    fstat(fd, &sb);
    return (size_t)sb.st_size;
}
static void* mmap_bundle(NSString* fn_bundle,intptr_t* psize){
    // Load item from predefined item bundle
    NSString *path = [[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent:fn_bundle];
    //    path = [[NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) lastObject]stringByAppendingPathComponent:fn_bundle];
    const char *fn = [path UTF8String];
    int fd = open(fn,O_RDONLY);
    void* g_res_zip = NULL;
    size_t g_res_size = 0;
    if(fd == -1){
        NSLog(@"faceunity: failed to open bundle");
        g_res_size = 0;
    }else{
        g_res_size = osal_GetFileSize(fd);
        g_res_zip = mmap(NULL, g_res_size, PROT_READ, MAP_SHARED, fd, 0);
        NSLog(@"faceunity: %@ mapped %08x %ld\n", path, (unsigned int)g_res_zip, g_res_size);
    }
    *psize = g_res_size;
    return g_res_zip;
    return nil;
}
- (void)fuReloadItem{
    if(g_items[0]){
        NSLog(@"faceunity: destroy item");
        fuDestroyItem(g_items[0]);
    }
    // load selected
    intptr_t size = g_mmap_sizes[g_selected_item];
    void* data = g_mmap_pointers[g_selected_item];
    if(!data){
        // mmap doesn't consume much hard resources, it should be safe to keep all the pointers around
        data = mmap_bundle(g_item_names[g_selected_item], &size);
        g_mmap_pointers[g_selected_item] = data;
        g_mmap_sizes[g_selected_item] = size;
    }
    // key item creation function call
    g_items[0] = fuCreateItemFromPackage(data, (int)size);
    NSLog(@"faceunity: load item #%d, handle=%d", g_selected_item, g_items[0]);
}

// Item draw interface with Qiniu pipeline
- (CVPixelBufferRef)addFaceunity:(CVPixelBufferRef)pixelBuffer time:(CMTime)time{
    // Initialize environment for faceunity
    //  Init GL context
    if(!g_gl_context){
        g_gl_context = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2];
    }
    if(!g_gl_context || ![EAGLContext setCurrentContext:g_gl_context]){
        NSLog(@"faceunity: failed to create / set a GLES2 context");
        return pixelBuffer;
    }
    //  Init face recgonition and tracking
    if(!g_faceplugin_inited){
        intptr_t size = 0;
        //        path = [[NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) lastObject]stringByAppendingPathComponent:@"v2.bundle"];
        //        if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        //            return pixelBuffer;
        //        }
        void* v2data = mmap_bundle(@"v2.bundle", &size);
        //        path = [[NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) lastObject]stringByAppendingPathComponent:@"ar.bundle"];
        //        if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        //            return pixelBuffer;
        //        }
        void* ardata = mmap_bundle(@"ar.bundle", &size);
        fuInit(v2data, ardata);
        g_faceplugin_inited = 1;
    }
    //  Load item if needed
    if (g_need_reload_item){
        //        path = [[NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) lastObject]stringByAppendingPathComponent:g_item_names[g_selected_item]];
        //        if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        //            return pixelBuffer;
        //        }
        [self fuReloadItem];
        g_need_reload_item = 0;
    }
    ////////////////////////////
    // Key draw functions
    CVPixelBufferLockBaseAddress(pixelBuffer, 0);
    //int w = (int)CVPixelBufferGetWidth(pixelBuffer);
    int h = (int)CVPixelBufferGetHeight(pixelBuffer);
    int stride = (int)CVPixelBufferGetBytesPerRow(pixelBuffer);
    int* img = (int*)CVPixelBufferGetBaseAddress(pixelBuffer);
    fuRenderItems(0, img, stride/4, h, g_frame_id, g_items, n_items);
    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
    g_frame_id++;
    return pixelBuffer;
}
- (void)openSticker{
    n_items = 1;
}
- (void)selectSticker:(NSInteger)index{
    g_selected_item = index - 1;
    g_need_reload_item = 1;
    dispatch_async(dispatch_get_main_queue(), ^{
        //self.itemHintText.text = g_item_hints[g_selected_item];
    });
}
- (void)closeSticker{
    n_items = 0;
}

-(void) ARGBTONV12:(CVPixelBufferRef)src time:(CMTime)timeStamp
{
    int width = (int)CVPixelBufferGetWidth(src);
    int height = (int)CVPixelBufferGetHeight(src);
    
    NSDictionary* pixelBufferOptions = @{ (NSString*) kCVPixelBufferPixelFormatTypeKey :
                                              @(kCVPixelFormatType_420YpCbCr8Planar),
                                          (NSString*) kCVPixelBufferWidthKey : @(width),
                                          (NSString*) kCVPixelBufferHeightKey : @(height),
                                          (NSString*) kCVPixelBufferOpenGLESCompatibilityKey : @YES,
                                          (NSString*) kCVPixelBufferIOSurfacePropertiesKey : @{}};
    
    CVPixelBufferRef dst;
    CVPixelBufferCreate(kCFAllocatorDefault,
                        width, height,
                        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                        (__bridge CFDictionaryRef)pixelBufferOptions,
                        &dst);
    CVPixelBufferLockBaseAddress(dst, 0);
    CVPixelBufferLockBaseAddress(src, 0);
    
    void* pSrc      = CVPixelBufferGetBaseAddressOfPlane(src, 0);
    size_t srcStride  = CVPixelBufferGetBytesPerRowOfPlane(src, 0);
    
    
    void* pDstY      = CVPixelBufferGetBaseAddressOfPlane(dst, 0);
    void* pDstUV      = CVPixelBufferGetBaseAddressOfPlane(dst, 1);
    size_t dstStrideY  = CVPixelBufferGetBytesPerRowOfPlane(dst, 0);
    size_t dstStrideUV = CVPixelBufferGetBytesPerRowOfPlane(dst, 1);
    
    int ret = ARGBToNV12((uint8*)pSrc, (int)srcStride,
                         (uint8*)pDstY,  (int)dstStrideY,
                         (uint8*)pDstUV, (int)dstStrideUV,
                         (int)width,  (int)height);
    
    int ARGBToNV21(const uint8* src_argb, int src_stride_argb,
                   uint8* dst_y, int dst_stride_y,
                   uint8* dst_vu, int dst_stride_vu,
                   int width, int height);
    if(ret != 0)
    {
        NSLog(@"I420ToNV12 failed,error is:%d",ret);
        CVPixelBufferUnlockBaseAddress(src, 0);
        CVPixelBufferUnlockBaseAddress(dst, 0);
        CFRelease(dst);
        return;
    }
    CVPixelBufferUnlockBaseAddress(src, 0);
    CVPixelBufferUnlockBaseAddress(dst, 0);
    
    [_yuvInput processPixelBuffer:dst time:timeStamp];
    CVPixelBufferRelease(dst);
    return;
}
//------------faceunity-------------//

- (instancetype)init {
    return [self initWithDefaultCfg];
}
- (void)dealloc {
    [_quitLock lock];
    [self closeKit];
    _bgmPlayer = nil;
    _streamerBase = nil;
    _vCapDev = nil;
    [_quitLock unlock];
    _quitLock = nil;
}

/* reset all submodules */
- (void) closeKit{
    [_bgmPlayer    stopPlayBgm];
    [_streamerBase stopStream];
    [_aCapDev      stopCapture];
    [_vCapDev      stopCameraCapture];
    
    [_vCapDev     removeAllTargets];
    [_cropfilter  removeAllTargets];
    [_filter      removeAllTargets];
    [_logoPic     removeAllTargets];
    [_textPic     removeAllTargets];
    [_vMixer      removeAllTargets];
}

/**
 @abstract   设置当前使用的滤镜
 @discussion 若filter 为nil， 则关闭滤镜
 @discussion 若filter 为GPUImageFilter的实例，则使用该滤镜做处理
 @discussion filter 也可以是GPUImageFilterGroup的实例，可以将多个滤镜组合
 
 @see GPUImageFilter
 */
- (void) setupFilter:(GPUImageOutput<GPUImageInput> *) filter {
    _filter = filter;
    if (_yuvInput  == nil) {
        return;
    }
    // 采集的图像先经过前处理
    [_yuvInput     removeAllTargets];
    GPUImageOutput* src = _yuvInput;
    if (_cropfilter) {
        [_cropfilter removeAllTargets];
        [src addTarget:_cropfilter];
        src = _cropfilter;
    }
    if (_filter) {
        [_filter removeAllTargets];
        [src addTarget:_filter];
        src = _filter;
    }
    // 组装图层
    _vMixer.masterLayer = _cameraLayer;
    [self addPic:src       ToMixerAt:_cameraLayer];
    [self addPic:_logoPic  ToMixerAt:_logoPicLayer];
    [self addPic:_textPic  ToMixerAt:_logoTxtLayer];
    // 混合后的图像输出到预览和推流
    [_vMixer removeAllTargets];
    [_vMixer addTarget:_preview];
    [_vMixer addTarget:_gpuToStr];
    // 设置镜像
    [self    setPreviewMirrored:_previewMirrored];
    [self    setStreamerMirrored:_streamerMirrored];
}
// 添加图层到 vMixer 中
- (void) addPic:(GPUImageOutput*)pic ToMixerAt: (NSInteger)idx{
    [_vMixer  clearPicOfLayer:idx];
    if (pic == nil){
        return;
    }
    [pic removeAllTargets];
    [pic addTarget:_vMixer atTextureLocation:idx];
}
// 组装视频通道
- (void) setupVideoPath {
    __weak KSYFaceunityKit * kit = self;
    // 前处理 和 图像 mixer
    [self setupFilter:_filter];
    // GPU 上的数据导出到streamer
    _gpuToStr.videoProcessingCallback = ^(CVPixelBufferRef pixelBuffer, CMTime timeInfo){
        if ([kit.streamerBase isStreaming]) {
            [kit.streamerBase processVideoPixelBuffer:pixelBuffer
                                             timeInfo:timeInfo];
        }
    };
    _vCapDev.videoProcessingCallback = ^(CMSampleBufferRef buf){
        if ( kit.videoProcessingCallback ){
            kit.videoProcessingCallback(buf);
        }
    };
}

// 将声音送入混音器
- (void) mixAudio:(CMSampleBufferRef)buf to:(int)idx{
    if (![_streamerBase isStreaming]){
        return;
    }
    [_aMixer processAudioSampleBuffer:buf of:idx];
}
// 组装声音通道
- (void) setupAudioPath {
    __weak KSYFaceunityKit * kit = self;
    //1. 音频采集, 语音数据送入混音器
    _aCapDev.audioProcessingCallback = ^(CMSampleBufferRef buf){
        [kit mixAudio:buf to:kit.micTrack];
    };
    //2. 背景音乐播放,音乐数据送入混音器
    _bgmPlayer.audioDataBlock = ^(CMSampleBufferRef buf){
        [kit mixAudio:buf to:kit.bgmTrack];
    };
    // 混音结果送入streamer
    _aMixer.audioProcessingCallback = ^(CMSampleBufferRef buf){
        if (![kit.streamerBase isStreaming]){
            return;
        }
        [kit.streamerBase processAudioSampleBuffer:buf];
    };
    // mixer 的主通道为麦克风,时间戳以main通道为准
    _aMixer.mainTrack = _micTrack;
    [_aMixer setTrack:_micTrack enable:YES];
    [_aMixer setTrack:_bgmTrack enable:YES];
}

#pragma mark - 状态通知
- (void) newCaptureState:(KSYCaptureState) state {
    dispatch_async(dispatch_get_main_queue(), ^{
        _captureState = state;
        NSNotificationCenter* dc =[NSNotificationCenter defaultCenter];
        [dc postNotificationName:KSYCaptureStateDidChangeNotification
                          object:self];
    });
}

#define CASE_RETURN( ENU ) case ENU : {return @#ENU;}
/**
 @abstract   获取采集状态对应的字符串
 */
- (NSString*) getCaptureStateName: (KSYCaptureState) stat{
    switch (stat){
            CASE_RETURN(KSYCaptureStateIdle)
            CASE_RETURN(KSYCaptureStateCapturing)
            CASE_RETURN(KSYCaptureStateDevAuthDenied)
            CASE_RETURN(KSYCaptureStateClosingCapture)
            CASE_RETURN(KSYCaptureStateParameterError)
            CASE_RETURN(KSYCaptureStateDevBusy)
        default: {    return @"unknow"; }
    }
}

- (NSString*) getCurCaptureStateName {
    return [self getCaptureStateName:_captureState];
}

#pragma mark - capture actions
/**
 @abstract 启动预览
 @param view 预览画面作为subview，插入到 view 的最底层
 @discussion 设置完成采集参数之后，按照设置值启动预览，启动后对采集参数修改不会生效
 @discussion 需要访问摄像头和麦克风的权限，若授权失败，其他API都会拒绝服务
 
 @warning: 开始推流前必须先启动预览
 @see videoDimension, cameraPosition, videoOrientation, videoFPS
 */
- (void) startPreview: (UIView*) view {
    if (_capDev_q == nil || view == nil || [_vCapDev isRunning]) {
        return;
    }
    AVAuthorizationStatus status_audio = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio];
    AVAuthorizationStatus status_video = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
    if ( status_audio == AVAuthorizationStatusDenied ||
        status_video == AVAuthorizationStatusDenied ) {
        [self newCaptureState:KSYCaptureStateDevAuthDenied];
        return;
    }
    dispatch_async(_capDev_q, ^{
        dispatch_async(dispatch_get_main_queue(), ^(){
            [view addSubview:_preview];
            [view sendSubviewToBack:_preview];
            _preview.frame = view.bounds;
        });
        if (_capPreset == nil) {
            [self newCaptureState:KSYCaptureStateParameterError];
            return;
        }
        [_quitLock lock];
        _vCapDev.captureSessionPreset = _capPreset;
        _vCapDev.frameRate = _videoFPS;
        
        if ( _cameraPosition != [_vCapDev cameraPosition] ){
            [_vCapDev rotateCamera];
        }
        //连接
        [self setupFilter:_filter];
        // 开始预览
        [_vCapDev startCameraCapture];
        [_aCapDev startCapture];
        [_quitLock unlock];
        [self newCaptureState:KSYCaptureStateCapturing];
    });
}

/**
 @abstract   停止预览，停止采集设备，并清理会话（step5）
 @discussion 若推流未结束，则先停止推流
 
 @see stopStream
 */
- (void) stopPreview {
    if (_vCapDev== nil ) {
        return;
    }
    [self newCaptureState:KSYCaptureStateClosingCapture];
    dispatch_async(_capDev_q, ^{
        [_quitLock lock];
        [self closeKit];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (_preview){
                [_preview removeFromSuperview];
            }
        });
        [_quitLock unlock];
        [self newCaptureState:KSYCaptureStateIdle];
    });
}
/**
 @abstract   查询实际的采集分辨率
 @discussion 参见iOS的 AVCaptureSessionPresetXXX的定义
 */
- (CGSize) captureDimension {
    if (_vCapDev){
        CMVideoDimensions dim;
        dim = CMVideoFormatDescriptionGetDimensions(_vCapDev.inputCamera.activeFormat.formatDescription);
        return CGSizeMake(dim.width, dim.height);
    }
    return CGSizeZero;
}
// 根据朝向, 判断是否需要交换宽和高
-(CGSize) updateDimensionOriention : (CGSize) sz{
    if ( ( self.videoOrientation == UIInterfaceOrientationPortraitUpsideDown ||
          self.videoOrientation == UIInterfaceOrientationPortrait ) &&
        (sz.width > sz.height) ) {
        float temp = sz.width;
        sz.width   = sz.height;
        sz.height  = temp;
    }
    return sz;
}
// 居中裁剪
-(CGRect) calcCropRect: (CGSize) camSz to: (CGSize) outSz {
    double x = (camSz.width  -outSz.width )/2/camSz.width;
    double y = (camSz.height -outSz.height)/2/camSz.height;
    double wdt = outSz.width/camSz.width;
    double hgt = outSz.height/camSz.height;
    return CGRectMake(x, y, wdt, hgt);
}

// 根据宽高比计算需要裁剪掉的区域
- (void) setupCropfilter {
    CGSize  inSz     =  [self captureDimension];
    inSz = [self updateDimensionOriention:inSz];
    CGFloat preRatio = _previewDimension.width / _previewDimension.height;
    CGSize cropSz = inSz; // set width
    cropSz.height = cropSz.width / preRatio;
    if (cropSz.height > inSz.height){
        cropSz.height = inSz.height; // set height
        cropSz.width  = cropSz.height * preRatio;
    }
    _cropfilter.cropRegion = [self calcCropRect:inSz to:cropSz];
}

// 更新分辨率相关设置
- (void) updateDimension {
    _previewDimension = [self updateDimensionOriention:_previewDimension];
    _streamDimension  = [self updateDimensionOriention:_streamDimension];
    [self setupCropfilter];
    [_vMixer forceProcessingAtSize:_previewDimension];
    _gpuToStr.outputSize = _streamDimension;
}

// 分辨率有效范围检查
@synthesize previewDimension = _previewDimension;
- (void) setPreviewDimension:(CGSize) sz{
    _previewDimension.width  = MAX(sz.width, sz.height);
    _previewDimension.height = MIN(sz.width, sz.height);
    _previewDimension.width  = MAX(160, MIN(_previewDimension.width, 1920));
    _previewDimension.height = MAX( 90, MIN(_previewDimension.height,1080));
}
@synthesize streamDimension = _streamDimension;
- (void) setStreamDimension:(CGSize) sz{
    _streamDimension.width  = MAX(sz.width, sz.height);
    _streamDimension.height = MIN(sz.width, sz.height);
    _streamDimension.width  = MAX(160, MIN(_streamDimension.width, 1280));
    _streamDimension.height = MAX( 90, MIN(_streamDimension.height, 720));
}
@synthesize videoFPS = _videoFPS;
- (void) setVideoFPS: (int) fps {
    _videoFPS = MAX(1, MIN(fps, 30));
}

@synthesize videoOrientation = _videoOrientation;
- (void) setVideoOrientation: (UIInterfaceOrientation) orie {
    _vCapDev.outputImageOrientation = orie;
    _videoOrientation = orie;
}
- (UIInterfaceOrientation) videoOrientation{
    return _vCapDev.outputImageOrientation;
}

/**
 @abstract   切换摄像头
 @return     TRUE: 成功切换摄像头， FALSE：当前参数，下一个摄像头不支持，切换失败
 @discussion 在前后摄像头间切换，从当前的摄像头切换到另一个，切换成功则修改cameraPosition的值
 @discussion 开始预览后开始有效，推流过程中也响应切换请求
 
 @see cameraPosition
 */
- (BOOL) switchCamera{
    if (_vCapDev == nil) {
        return NO;
    }
    _cameraPosition = _vCapDev.cameraPosition;
    [_vCapDev rotateCamera];
    if (_cameraPosition == _vCapDev.cameraPosition) {
        return  NO;
    }
    _cameraPosition = _vCapDev.cameraPosition;
    return YES;
}

/**
 @abstract   当前采集设备是否支持闪光灯
 @return     YES / NO
 @discussion 通常只有后置摄像头支持闪光灯
 
 @see setTorchMode
 */
- (BOOL) isTorchSupported{
    if (_vCapDev){
        return _vCapDev.isTorchSupported;
    }
    return NO;
}

/**
 @abstract   开关闪光灯
 @discussion 切换闪光灯的开关状态 开 <--> 关
 
 @see setTorchMode
 */
- (void) toggleTorch {
    if (_vCapDev){
        [_vCapDev toggleTorch];
    }
}

/**
 @abstract   设置闪光灯
 @param      mode  AVCaptureTorchModeOn/Off
 @discussion 设置闪光灯的开关状态
 @discussion 开始预览后开始有效
 
 @see AVCaptureTorchMode
 */
- (void) setTorchMode: (AVCaptureTorchMode)mode{
    if (_vCapDev){
        [_vCapDev setTorchMode:mode];
    }
}

/**
 @abstract   获取当前采集设备的指针
 
 @discussion 开放本指针的目的是开放类似下列添加到AVCaptureDevice的 categories：
 - AVCaptureDeviceFlash
 - AVCaptureDeviceTorch
 - AVCaptureDeviceFocus
 - AVCaptureDeviceExposure
 - AVCaptureDeviceWhiteBalance
 - etc.
 
 @return AVCaptureDevice* 预览开始前调用返回为nil，开始预览后，返回当前正在使用的摄像头
 
 @warning  请勿修改摄像头的像素格式，帧率，分辨率等参数，修改后会导致推流工作异常或崩溃
 @see AVCaptureDevice  AVCaptureDeviceTorch AVCaptureDeviceFocus
 */
- (AVCaptureDevice*) getCurrentCameraDevices {
    if (_vCapDev){
        return _vCapDev.inputCamera;
    }
    return nil;
}

#pragma mark - mirror
- (void) customAudioProcessing: (CMSampleBufferRef) buf{
    
}

- (void) setPreviewMirrored:(BOOL)bMirrored {
    if(_preview){
        GPUImageRotationMode ro = bMirrored ? kGPUImageFlipHorizonal :kGPUImageNoRotation;
        [_preview setInputRotation:ro atIndex:0];
    }
    _previewMirrored = bMirrored;
    return ;
}

- (void) setStreamerMirrored:(BOOL)bMirrored {
    if (_gpuToStr){
        GPUImageRotationMode ro = bMirrored ? kGPUImageFlipHorizonal :kGPUImageNoRotation;
        [_gpuToStr setInputRotation:ro atIndex:0];
    }
    _streamerMirrored = bMirrored;
}

#pragma mark - utils
-(UIImage *)imageFromUILable:(UILabel *)labal {
    UIFont *font =labal.font;
    NSDictionary *textAttributes =
    @{NSFontAttributeName           : font,
      NSForegroundColorAttributeName: labal.textColor,
      NSBackgroundColorAttributeName: labal.backgroundColor};
    CGSize size = [labal.text sizeWithAttributes:textAttributes];
    UIGraphicsBeginImageContextWithOptions(size,NO,0.0);
    CGRect drawRect = CGRectMake(0.0, 0.0, 200.0, 100.0);
    [labal.text drawInRect:drawRect withAttributes:textAttributes];
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return image;
}

- (UIImage *)resizeImage:(UIImage*)image newSize:(CGSize)newSize {
    CGRect newRect = CGRectIntegral(CGRectMake(0, 0, newSize.width, newSize.height));
    CGImageRef imageRef = image.CGImage;
    UIGraphicsBeginImageContextWithOptions(newSize, NO, 0);
    CGContextRef context = UIGraphicsGetCurrentContext();
    CGContextSetInterpolationQuality(context, kCGInterpolationHigh);
    CGAffineTransform flipVertical = CGAffineTransformMake(1, 0, 0, -1, 0, newSize.height);
    CGContextConcatCTM(context, flipVertical);
    CGContextDrawImage(context, newRect, imageRef);
    CGImageRef newImageRef = CGBitmapContextCreateImage(context);
    UIImage *newImage = [UIImage imageWithCGImage:newImageRef];
    CGImageRelease(newImageRef);
    UIGraphicsEndImageContext();
    return newImage;
}

#pragma mark - pictures & logo
@synthesize logoPic = _logoPic;
-(void) setLogoPic:(GPUImagePicture *)pic{
    _logoPic = pic;
    [self addPic:_logoPic ToMixerAt:_logoPicLayer];
}
// 水印logo的图片的位置和大小
@synthesize logoRect = _logoRect;
- (CGRect) logoRect {
    return [_vMixer getPicRectOfLayer:_logoPicLayer];
}
- (void) setLogoRect:(CGRect)logoRect{
    [_vMixer setPicRect:logoRect
                ofLayer:_logoPicLayer];
}
// 水印logo的图片的透明度
@synthesize logoAlpha = _logoAlpha;
- (CGFloat)logoAlpha{
    return [_vMixer getPicAlphaOfLayer:_logoPicLayer];
}
- (void)setLogoAlpha:(CGFloat)alpha{
    return [_vMixer setPicAlpha:alpha ofLayer:_logoPicLayer];
}
// 水印文字的位置
@synthesize textRect = _textRect;
- (CGRect) textRect {
    return [_vMixer getPicRectOfLayer:_logoTxtLayer];
}
- (void) setTextRect:(CGRect)rect{
    [_vMixer setPicRect:rect
                ofLayer:_logoTxtLayer];
}
/**
 @abstract   刷新水印文字的内容
 @discussion 先修改文字的内容或格式,调用该方法后生效
 @see textLable
 */
- (void) updateTextLable{
    if ( [_textLable.text length] <= 0 ){
        _textPic = nil;
        [_vMixer  clearPicOfLayer:_logoPicLayer];
        return;
    }
    UIImage * img = [self imageFromUILable:_textLable];
    _textPic = [[GPUImagePicture alloc] initWithImage:img];
    [self addPic:_textPic ToMixerAt:_logoTxtLayer];
    [_textPic processImage];
}

@end
