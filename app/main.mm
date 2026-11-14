// XRProbe — первый шаг порта S.T.A.L.K.E.R. на iOS.
//
// Пробное приложение, которое проверяет на настоящем iPhone то, что нельзя проверить без Mac:
//   1. Нативный хост: UIScene + CAMetalLayer + CADisplayLink, альбомная ориентация, жизненный цикл.
//   2. Metal: рендер треугольника из MSL, скомпилированного прямо на устройстве.
//   3. Шейдеры OpenXRay: каждый MSL-файл, полученный из GL-шейдеров движка
//      (GLSL → SPIR-V → MSL), компилируется драйвером Metal на телефоне. Итог — в логе.
//   4. Память: сколько реально можно занять до jetsam (сравнить SideStore- и TrollStore-сборки).
//   5. Возможности GPU: семейства Apple GPU, поддержка BC-сжатия текстур (DXT из игры).
//
// Лог пишется в Documents/xrprobe.log — его видно в приложении «Файлы».

#import <UIKit/UIKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#include <os/proc.h>
#include <sys/utsname.h>
#include <sys/sysctl.h>
#include <vector>
#include <atomic>
#include <cstdlib>
#include <cstring>

#pragma mark - Лог

static NSFileHandle* gLogHandle = nil;
static NSString* gLogPath = nil;
static dispatch_queue_t gLogQueue;

static NSString* DocumentsDir()
{
    return NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
}

static void LogOpen()
{
    gLogQueue = dispatch_queue_create("xrprobe.log", DISPATCH_QUEUE_SERIAL);
    gLogPath = [DocumentsDir() stringByAppendingPathComponent:@"xrprobe.log"];
    [[NSFileManager defaultManager] createFileAtPath:gLogPath contents:nil attributes:nil];
    gLogHandle = [NSFileHandle fileHandleForWritingAtPath:gLogPath];
}

static void XRLog(NSString* format, ...) NS_FORMAT_FUNCTION(1, 2);
static void XRLog(NSString* format, ...)
{
    va_list args;
    va_start(args, format);
    NSString* msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSLog(@"[XRProbe] %@", msg);
    NSString* line = [NSString stringWithFormat:@"%.3f %@\n", CACurrentMediaTime(), msg];
    dispatch_async(gLogQueue, ^{
        [gLogHandle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    });
}

#pragma mark - Сведения об устройстве

static NSString* MachineModel()
{
    struct utsname u;
    uname(&u);
    return [NSString stringWithUTF8String:u.machine];
}

static double AvailableMemoryMB()
{
    return double(os_proc_available_memory()) / (1024.0 * 1024.0);
}

static NSString* ThermalName(NSProcessInfoThermalState s)
{
    switch (s)
    {
    case NSProcessInfoThermalStateNominal: return @"норма";
    case NSProcessInfoThermalStateFair: return @"тепло";
    case NSProcessInfoThermalStateSerious: return @"горячо";
    case NSProcessInfoThermalStateCritical: return @"критично";
    }
    return @"?";
}

static NSString* GPUFamilies(id<MTLDevice> dev)
{
    // Сырые значения MTLGPUFamilyApple1..Apple10 (1001..1010), чтобы код собирался с любым SDK.
    NSMutableArray* list = [NSMutableArray array];
    for (NSInteger v = 1001; v <= 1010; ++v)
        if ([dev supportsFamily:(MTLGPUFamily)v])
            [list addObject:[NSString stringWithFormat:@"Apple%ld", (long)(v - 1000)]];
    return [list componentsJoinedByString:@" "];
}

static BOOL SupportsBC(id<MTLDevice> dev)
{
    // Свойство появилось в iOS 16.4; проверяем через селектор, чтобы не тянуть @available
    // (так файл линкуется и тулчейном на Linux).
    SEL sel = NSSelectorFromString(@"supportsBCTextureCompression");
    if (![(id)dev respondsToSelector:sel])
        return NO;
    return [[(id)dev valueForKey:@"supportsBCTextureCompression"] boolValue];
}

#pragma mark - Тест шейдеров OpenXRay

@interface XRShaderTest : NSObject
@property(atomic) NSInteger total, done, failed;
@property(atomic) double seconds;
@property(atomic) BOOL running;
- (void)runWithDevice:(id<MTLDevice>)device;
@end

@implementation XRShaderTest
- (void)runWithDevice:(id<MTLDevice>)device
{
    if (self.running)
        return;
    NSString* dir = [[NSBundle mainBundle].resourcePath stringByAppendingPathComponent:@"xrshaders"];
    NSArray<NSString*>* files = [[[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil]
        filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"self ENDSWITH '.metal'"]];
    files = [files sortedArrayUsingSelector:@selector(compare:)];
    self.total = files.count;
    self.done = 0;
    self.failed = 0;
    self.running = YES;
    XRLog(@"Шейдеры OpenXRay: найдено %lu MSL-файлов", (unsigned long)files.count);

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        MTLCompileOptions* opts = [MTLCompileOptions new];
        opts.languageVersion = MTLLanguageVersion2_1;
        CFTimeInterval start = CACurrentMediaTime();
        for (NSString* name in files)
        {
            @autoreleasepool
            {
                NSString* src = [NSString stringWithContentsOfFile:[dir stringByAppendingPathComponent:name]
                                                          encoding:NSUTF8StringEncoding
                                                             error:nil];
                NSError* err = nil;
                CFTimeInterval t0 = CACurrentMediaTime();
                id<MTLLibrary> lib = src ? [device newLibraryWithSource:src options:opts error:&err] : nil;
                id<MTLFunction> fn = [lib newFunctionWithName:@"main0"];
                double ms = (CACurrentMediaTime() - t0) * 1000.0;
                if (!fn)
                {
                    self.failed = self.failed + 1;
                    NSString* e = err.localizedDescription ?: @"нет функции main0";
                    XRLog(@"  FAIL %@ (%.0f мс): %@", name, ms, [e substringToIndex:MIN(e.length, (NSUInteger)600)]);
                }
                else if (ms > 500)
                {
                    XRLog(@"  ok   %@ — долго: %.0f мс", name, ms);
                }
                self.done = self.done + 1;
            }
        }
        self.seconds = CACurrentMediaTime() - start;
        self.running = NO;
        XRLog(@"Шейдеры OpenXRay: готово %ld/%ld, ошибок %ld, всего %.1f с",
              (long)(self.done - self.failed), (long)self.total, (long)self.failed, self.seconds);
    });
}
@end

#pragma mark - Тест памяти

// Занимает память блоками по 32 МБ (с записью в каждую страницу), пока
// os_proc_available_memory() не опустится ниже запаса. Затем всё освобождает.
// Показывает реальный бюджет приложения до jetsam для этой сборки и этого телефона.
// ---------------------------------------------------------------------------
// Офлайн-библиотека xrshaders.metallib (собрана в CI): для Metal-рендера движка.
// Проверяем, что из неё на этом GPU создаются настоящие PSO:
//   * вершинный шейдер — PSO без растеризации, вершинный формат из отражения Metal;
//   * пиксельный — PSO с подставным вершинным шейдером, который выдаёт ровно те
//     входы [[user(locnN)]], что ждёт пиксельный (берём из *.json от SPIRV-Cross).
// ---------------------------------------------------------------------------
static NSString* MSLType(NSString* glsl)
{
    NSDictionary* map = @{ @"float": @"float", @"vec2": @"float2", @"vec3": @"float3", @"vec4": @"float4",
                           @"int": @"int", @"ivec2": @"int2", @"ivec3": @"int3", @"ivec4": @"int4",
                           @"uint": @"uint", @"uvec2": @"uint2", @"uvec3": @"uint3", @"uvec4": @"uint4" };
    return map[glsl];
}

static MTLVertexFormat AttrFormat(MTLDataType t)
{
    switch (t)
    {
    case MTLDataTypeFloat: return MTLVertexFormatFloat;
    case MTLDataTypeFloat2: return MTLVertexFormatFloat2;
    case MTLDataTypeFloat3: return MTLVertexFormatFloat3;
    case MTLDataTypeFloat4: return MTLVertexFormatFloat4;
    case MTLDataTypeInt: return MTLVertexFormatInt;
    case MTLDataTypeInt2: return MTLVertexFormatInt2;
    case MTLDataTypeInt3: return MTLVertexFormatInt3;
    case MTLDataTypeInt4: return MTLVertexFormatInt4;
    case MTLDataTypeUInt: return MTLVertexFormatUInt;
    case MTLDataTypeUInt2: return MTLVertexFormatUInt2;
    case MTLDataTypeUInt3: return MTLVertexFormatUInt3;
    case MTLDataTypeUInt4: return MTLVertexFormatUInt4;
    default: return MTLVertexFormatFloat4;
    }
}

static void RunMetallibTest(id<MTLDevice> device)
{
    NSString* res = [NSBundle mainBundle].resourcePath;
    NSString* libPath = [res stringByAppendingPathComponent:@"xrshaders.metallib"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:libPath])
    {
        XRLog(@"metallib: нет в пакете — пропускаю");
        return;
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSError* err = nil;
        CFTimeInterval t0 = CACurrentMediaTime();
        id<MTLLibrary> lib = [device newLibraryWithURL:[NSURL fileURLWithPath:libPath] error:&err];
        if (!lib)
        {
            XRLog(@"metallib: НЕ загрузилась: %@", err.localizedDescription);
            return;
        }
        NSArray<NSString*>* names = [lib.functionNames sortedArrayUsingSelector:@selector(compare:)];
        XRLog(@"metallib: загружена за %.0f мс, функций %lu", (CACurrentMediaTime() - t0) * 1000.0,
              (unsigned long)names.count);
        NSString* jsonDir = [res stringByAppendingPathComponent:@"xrshaders"];
        NSInteger okV = 0, okP = 0, fail = 0;
        CFTimeInterval start = CACurrentMediaTime();
        for (NSString* name in names)
        {
            @autoreleasepool
            {
                id<MTLFunction> fn = [lib newFunctionWithName:name];
                MTLRenderPipelineDescriptor* pd = [MTLRenderPipelineDescriptor new];
                pd.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
                if (fn.functionType == MTLFunctionTypeVertex)
                {
                    MTLVertexDescriptor* vd = [MTLVertexDescriptor new];
                    NSUInteger offset = 0;
                    for (MTLVertexAttribute* a in fn.vertexAttributes)
                    {
                        if (!a.active)
                            continue;
                        vd.attributes[a.attributeIndex].format = AttrFormat(a.attributeType);
                        vd.attributes[a.attributeIndex].offset = offset;
                        vd.attributes[a.attributeIndex].bufferIndex = 30;
                        offset += 16;
                    }
                    vd.layouts[30].stride = MAX(offset, (NSUInteger)16);
                    pd.vertexFunction = fn;
                    pd.vertexDescriptor = vd;
                    pd.rasterizationEnabled = NO;
                }
                else
                {
                    // Входы и выходы пиксельного шейдера — из отражения SPIRV-Cross
                    NSData* jd = [NSData dataWithContentsOfFile:[jsonDir stringByAppendingPathComponent:
                                                                    [name stringByAppendingString:@".json"]]];
                    NSDictionary* js = jd ? [NSJSONSerialization JSONObjectWithData:jd options:0 error:nil] : nil;
                    NSMutableString* members = [NSMutableString new];
                    NSMutableString* zeros = [NSMutableString new];
                    for (NSDictionary* in in js[@"inputs"])
                    {
                        NSString* t = MSLType(in[@"type"]);
                        if (!t)
                            continue;
                        [members appendFormat:@"  %@ v%@ [[user(locn%@)]];\n", t, in[@"location"], in[@"location"]];
                        [zeros appendFormat:@"  o.v%@ = %@(0);\n", in[@"location"], t];
                    }
                    NSString* src = [NSString stringWithFormat:
                        @"#include <metal_stdlib>\nusing namespace metal;\n"
                         "struct VOut {\n  float4 pos [[position]];\n%@};\n"
                         "vertex VOut xr_dummy_vs(uint vid [[vertex_id]]) {\n  VOut o;\n  o.pos = float4(0);\n%@  return o;\n}\n",
                        members, zeros];
                    id<MTLLibrary> vl = [device newLibraryWithSource:src options:nil error:&err];
                    pd.vertexFunction = [vl newFunctionWithName:@"xr_dummy_vs"];
                    pd.fragmentFunction = fn;
                    for (NSDictionary* out in js[@"outputs"])
                    {
                        NSUInteger loc = [out[@"location"] unsignedIntegerValue];
                        NSString* t = out[@"type"];
                        pd.colorAttachments[loc].pixelFormat = [t hasPrefix:@"ivec"] || [t isEqual:@"int"]
                            ? MTLPixelFormatRGBA32Sint
                            : ([t hasPrefix:@"uvec"] || [t isEqual:@"uint"]) ? MTLPixelFormatRGBA32Uint
                                                                            : MTLPixelFormatRGBA16Float;
                    }
                }
                err = nil;
                id<MTLRenderPipelineState> pso = [device newRenderPipelineStateWithDescriptor:pd error:&err];
                if (pso)
                    fn.functionType == MTLFunctionTypeVertex ? ++okV : ++okP;
                else
                {
                    ++fail;
                    NSString* e = err.localizedDescription ?: @"?";
                    XRLog(@"  PSO FAIL %@: %@", name, [e substringToIndex:MIN(e.length, (NSUInteger)300)]);
                }
            }
        }
        XRLog(@"metallib: PSO готовы — вершинных %ld, пиксельных %ld, ошибок %ld, за %.1f с", (long)okV, (long)okP,
              (long)fail, CACurrentMediaTime() - start);
    });
}

static std::atomic<bool> gMemTestRunning{false};
static std::atomic<double> gMemTestResultMB{0};

static void RunMemoryTest()
{
    if (gMemTestRunning.exchange(true))
        return;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        const size_t chunk = 32u << 20;
        const double reserveMB = 150.0;
        std::vector<void*> blocks;
        double startAvail = AvailableMemoryMB();
        XRLog(@"Тест памяти: доступно в начале %.0f МБ", startAvail);
        while (AvailableMemoryMB() - 32.0 > reserveMB)
        {
            void* p = std::malloc(chunk);
            if (!p)
                break;
            std::memset(p, 0x5A, chunk); // реально занимаем страницы
            blocks.push_back(p);
        }
        double gotMB = blocks.size() * 32.0;
        for (void* p : blocks)
            std::free(p);
        gMemTestResultMB = gotMB;
        XRLog(@"Тест памяти: удалось занять %.0f МБ (запас %.0f МБ), после освобождения доступно %.0f МБ",
              gotMB, reserveMB, AvailableMemoryMB());
        gMemTestRunning = false;
    });
}

#pragma mark - Metal-вид

static const char* const kTriangleMSL = R"MSL(
#include <metal_stdlib>
using namespace metal;
struct VOut { float4 pos [[position]]; float3 color; };
vertex VOut tri_vs(uint vid [[vertex_id]], constant float& t [[buffer(0)]])
{
    const float2 p[3] = { float2(0.0, 0.6), float2(-0.52, -0.3), float2(0.52, -0.3) };
    const float3 c[3] = { float3(0.85, 0.55, 0.15), float3(0.35, 0.45, 0.20), float3(0.55, 0.55, 0.50) };
    float s = sin(t), k = cos(t);
    float2 q = float2(p[vid].x * k - p[vid].y * s, p[vid].x * s + p[vid].y * k);
    VOut o; o.pos = float4(q * 0.6, 0.0, 1.0); o.color = c[vid]; return o;
}
fragment float4 tri_fs(VOut in [[stage_in]]) { return float4(in.color, 1.0); }
)MSL";

@interface XRMetalView : UIView
@property(nonatomic, readonly) CAMetalLayer* metalLayer;
@end

@implementation XRMetalView
+ (Class)layerClass { return [CAMetalLayer class]; }
- (CAMetalLayer*)metalLayer { return (CAMetalLayer*)self.layer; }
@end

#pragma mark - Контроллер

@interface XRViewController : UIViewController
@property(nonatomic) BOOL active;
- (void)setActive:(BOOL)active;
@end

@implementation XRViewController
{
    id<MTLDevice> _device;
    id<MTLCommandQueue> _queue;
    id<MTLRenderPipelineState> _pipeline;
    dispatch_semaphore_t _inFlight;
    CADisplayLink* _link;
    XRMetalView* _metalView;
    UILabel* _overlay;
    XRShaderTest* _shaderTest;
    CFTimeInterval _startTime, _lastFrame, _lastOverlay;
    double _frameMsAvg;
    NSInteger _touches;
}

- (void)loadView
{
    _metalView = [[XRMetalView alloc] initWithFrame:UIScreen.mainScreen.bounds];
    _metalView.multipleTouchEnabled = YES;
    self.view = _metalView;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    _device = MTLCreateSystemDefaultDevice();
    _queue = [_device newCommandQueue];
    _inFlight = dispatch_semaphore_create(3);
    _shaderTest = [XRShaderTest new];
    _startTime = CACurrentMediaTime();

    CAMetalLayer* layer = _metalView.metalLayer;
    layer.device = _device;
    layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    layer.framebufferOnly = YES;
    layer.maximumDrawableCount = 3;

    NSError* err = nil;
    id<MTLLibrary> lib = [_device newLibraryWithSource:@(kTriangleMSL) options:nil error:&err];
    MTLRenderPipelineDescriptor* pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = [lib newFunctionWithName:@"tri_vs"];
    pd.fragmentFunction = [lib newFunctionWithName:@"tri_fs"];
    pd.colorAttachments[0].pixelFormat = layer.pixelFormat;
    _pipeline = [_device newRenderPipelineStateWithDescriptor:pd error:&err];
    if (!_pipeline)
        XRLog(@"ОШИБКА: не создан PSO треугольника: %@", err);

    [self buildOverlay];
    [self logDeviceInfo];

    _link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
    _link.preferredFrameRateRange = CAFrameRateRangeMake(30, 60, 60); // iOS 15+ — минимум приложения
    [_link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    self.active = YES;

    [_shaderTest runWithDevice:_device];
    RunMetallibTest(_device);
}

- (void)logDeviceInfo
{
    UIDevice* d = UIDevice.currentDevice;
    XRLog(@"Устройство: %@, %@ %@", MachineModel(), d.systemName, d.systemVersion);
    XRLog(@"ОЗУ: %.0f МБ физически, доступно процессу %.0f МБ",
          NSProcessInfo.processInfo.physicalMemory / (1024.0 * 1024.0), AvailableMemoryMB());
    XRLog(@"GPU: %@; семейства: %@; BC (DXT): %@; maxBufferLength %.0f МБ",
          _device.name, GPUFamilies(_device), SupportsBC(_device) ? @"да" : @"нет",
          _device.maxBufferLength / (1024.0 * 1024.0));
    XRLog(@"Экран: %.0fx%.0f pt, scale %.1f, max FPS %ld", UIScreen.mainScreen.bounds.size.width,
          UIScreen.mainScreen.bounds.size.height, UIScreen.mainScreen.nativeScale,
          (long)UIScreen.mainScreen.maximumFramesPerSecond);
    XRLog(@"Лог: %@", gLogPath);
}

- (UIButton*)buttonWithTitle:(NSString*)title action:(SEL)action
{
    UIButton* b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    b.backgroundColor = [UIColor colorWithWhite:0.15 alpha:0.75];
    b.layer.cornerRadius = 8;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    b.contentEdgeInsets = UIEdgeInsetsMake(8, 14, 8, 14); // iOS 15: UIButtonConfiguration — позже
#pragma clang diagnostic pop
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (void)buildOverlay
{
    _overlay = [UILabel new];
    _overlay.numberOfLines = 0;
    _overlay.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    _overlay.textColor = UIColor.whiteColor;
    _overlay.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
    _overlay.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_overlay];

    UIStackView* buttons = [[UIStackView alloc] initWithArrangedSubviews:@[
        [self buttonWithTitle:@"Тест памяти" action:@selector(onMemory)],
        [self buttonWithTitle:@"Шейдеры заново" action:@selector(onShaders)],
        [self buttonWithTitle:@"Поделиться логом" action:@selector(onShareLog:)],
    ]];
    buttons.axis = UILayoutConstraintAxisHorizontal;
    buttons.spacing = 10;
    buttons.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:buttons];

    UILayoutGuide* g = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [_overlay.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:8],
        [_overlay.topAnchor constraintEqualToAnchor:g.topAnchor constant:8],
        [_overlay.widthAnchor constraintLessThanOrEqualToAnchor:g.widthAnchor multiplier:0.6],
        [buttons.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-8],
        [buttons.bottomAnchor constraintEqualToAnchor:g.bottomAnchor constant:-8],
    ]];
}

- (void)onMemory { RunMemoryTest(); }
- (void)onShaders { [_shaderTest runWithDevice:_device]; }

- (void)onShareLog:(UIButton*)sender
{
    NSURL* url = [NSURL fileURLWithPath:gLogPath];
    UIActivityViewController* vc = [[UIActivityViewController alloc] initWithActivityItems:@[ url ]
                                                                     applicationActivities:nil];
    vc.popoverPresentationController.sourceView = sender;
    [self presentViewController:vc animated:YES completion:nil];
}

- (void)setActive:(BOOL)active
{
    _active = active;
    _link.paused = !active; // в фоне GPU-работа запрещена — останавливаем кадры
    _lastFrame = 0;
    XRLog(active ? @"Активно: рендер запущен" : @"Неактивно: рендер остановлен");
}

- (void)tick:(CADisplayLink*)link
{
    if (!_active || !_pipeline)
        return;
    CFTimeInterval now = CACurrentMediaTime();
    if (_lastFrame > 0)
        _frameMsAvg = _frameMsAvg * 0.95 + (now - _lastFrame) * 1000.0 * 0.05;
    _lastFrame = now;

    CAMetalLayer* layer = _metalView.metalLayer;
    CGSize sz = self.view.bounds.size;
    CGFloat scale = self.view.window.screen.nativeScale ?: 2.0;
    CGSize want = CGSizeMake(sz.width * scale, sz.height * scale);
    if (!CGSizeEqualToSize(layer.drawableSize, want))
        layer.drawableSize = want;

    dispatch_semaphore_wait(_inFlight, DISPATCH_TIME_FOREVER);
    id<CAMetalDrawable> drawable = [layer nextDrawable];
    if (!drawable)
    {
        dispatch_semaphore_signal(_inFlight);
        return;
    }
    MTLRenderPassDescriptor* rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = drawable.texture;
    rp.colorAttachments[0].loadAction = MTLLoadActionClear;
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    rp.colorAttachments[0].clearColor = MTLClearColorMake(0.08, 0.09, 0.07, 1.0);

    id<MTLCommandBuffer> cb = [_queue commandBuffer];
    cb.label = @"XRProbe frame";
    id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
    [enc pushDebugGroup:@"triangle"];
    float t = float(now - _startTime);
    [enc setRenderPipelineState:_pipeline];
    [enc setVertexBytes:&t length:sizeof(t) atIndex:0];
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [enc popDebugGroup];
    [enc endEncoding];
    [cb presentDrawable:drawable];
    dispatch_semaphore_t sem = _inFlight;
    [cb addCompletedHandler:^(id<MTLCommandBuffer> b) {
        if (b.error)
            XRLog(@"Ошибка GPU: %@", b.error);
        dispatch_semaphore_signal(sem);
    }];
    [cb commit];

    if (now - _lastOverlay > 0.25)
    {
        _lastOverlay = now;
        [self updateOverlay];
    }
}

- (void)updateOverlay
{
    NSString* shaders = _shaderTest.total == 0
        ? @"нет файлов"
        : [NSString stringWithFormat:@"%ld/%ld, ошибок %ld%@", (long)_shaderTest.done, (long)_shaderTest.total,
                                     (long)_shaderTest.failed,
                                     _shaderTest.running ? @" …" : [NSString stringWithFormat:@" (%.1f с)", _shaderTest.seconds]];
    NSString* mem = gMemTestRunning ? @"идёт…"
                    : gMemTestResultMB > 0 ? [NSString stringWithFormat:@"занято до %.0f МБ", gMemTestResultMB.load()]
                                           : @"не запускался";
    _overlay.text = [NSString stringWithFormat:
        @" XRProbe %@ · S.T.A.L.K.E.R. iOS \n"
         " %@ · iOS %@ \n"
         " GPU: %@ \n"
         " Семейства: %@ · BC: %@ \n"
         " Кадр: %.1f мс (%.0f FPS) · касаний: %ld \n"
         " Доступно памяти: %.0f МБ · нагрев: %@ \n"
         " Тест памяти: %@ \n"
         " Шейдеры OpenXRay: %@ ",
        [NSBundle mainBundle].infoDictionary[@"XRVariant"] ?: @"", MachineModel(), UIDevice.currentDevice.systemVersion, _device.name, GPUFamilies(_device),
        SupportsBC(_device) ? @"да" : @"нет", _frameMsAvg, _frameMsAvg > 0 ? 1000.0 / _frameMsAvg : 0.0,
        (long)_touches, AvailableMemoryMB(), ThermalName(NSProcessInfo.processInfo.thermalState), mem, shaders];
}

- (void)touchesBegan:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event { _touches = event.allTouches.count; }
- (void)touchesEnded:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event { _touches = 0; }
- (void)touchesCancelled:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event { _touches = 0; }

- (BOOL)prefersStatusBarHidden { return YES; }
- (BOOL)prefersHomeIndicatorAutoHidden { return YES; }
- (UIRectEdge)preferredScreenEdgesDeferringSystemGestures { return UIRectEdgeAll; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }
@end

#pragma mark - Сцена и приложение

@interface XRSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property(strong, nonatomic) UIWindow* window;
@end

@implementation XRSceneDelegate
- (void)scene:(UIScene*)scene willConnectToSession:(UISceneSession*)session options:(UISceneConnectionOptions*)options
{
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene*)scene];
    self.window.rootViewController = [XRViewController new];
    [self.window makeKeyAndVisible];
}
- (XRViewController*)controller { return (XRViewController*)self.window.rootViewController; }
- (void)sceneDidBecomeActive:(UIScene*)scene { [[self controller] setActive:YES]; }
- (void)sceneWillResignActive:(UIScene*)scene { [[self controller] setActive:NO]; }
- (void)sceneDidEnterBackground:(UIScene*)scene { XRLog(@"Ушли в фон"); }
@end

@interface XRAppDelegate : UIResponder <UIApplicationDelegate>
@end

@implementation XRAppDelegate
- (BOOL)application:(UIApplication*)app didFinishLaunchingWithOptions:(NSDictionary*)opts
{
    NSDictionary* info = [NSBundle mainBundle].infoDictionary;
    XRLog(@"Запуск XRProbe %@, сборка %@", info[@"CFBundleShortVersionString"], info[@"XRVariant"] ?: @"?");
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidReceiveMemoryWarningNotification
                                                      object:nil
                                                       queue:nil
                                                  usingBlock:^(NSNotification*) {
                                                      XRLog(@"Предупреждение о нехватке памяти, доступно %.0f МБ",
                                                            AvailableMemoryMB());
                                                  }];
    return YES;
}
- (UISceneConfiguration*)application:(UIApplication*)app
    configurationForConnectingSceneSession:(UISceneSession*)session
                                   options:(UISceneConnectionOptions*)options
{
    UISceneConfiguration* c = [[UISceneConfiguration alloc] initWithName:@"Default" sessionRole:session.role];
    c.delegateClass = [XRSceneDelegate class];
    return c;
}
@end

int main(int argc, char* argv[])
{
    @autoreleasepool
    {
        LogOpen();
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([XRAppDelegate class]));
    }
}
