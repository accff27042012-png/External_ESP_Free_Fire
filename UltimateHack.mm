#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#include <mach/mach.h>
#include <math.h>
#include <sys/sysctl.h>

// ============================================================
// OFFSET THỰC TẾ TỪ DUMP.CS CỦA MÀY
// ============================================================
// Position (từ AxisPosX/Y/Z - IMG_0849)
#define OFFSET_POSITION_X       0xC8
#define OFFSET_POSITION_Y       0xC4
#define OFFSET_POSITION_Z       0xD0

// EntityList và PlayerList (từ COW.UIHudMatchR - IMG_0862)
#define OFFSET_ENTITY_LIST      0x440
#define OFFSET_PLAYER_LIST      0x450

// ViewMatrix (tạm dùng 0x1B0 từ Camera.worldToCameraMatrix)
#define OFFSET_VIEW_MATRIX      0x1B0

// CameraControllerBase (từ IMG_0852)
#define OFFSET_CAMERA_CONTROLLER_BASE  0x30  // ALGPBKBFAL

// Transform (từ IMG_0847)
#define OFFSET_TRANSFORM_POSITION  0x10  // Transform.position

// ============================================================
// VECTOR3
// ============================================================
struct Vector3 {
    float x, y, z;
    Vector3() : x(0), y(0), z(0) {}
    Vector3(float x, float y, float z) : x(x), y(y), z(z) {}
    
    static float Distance(Vector3 a, Vector3 b) {
        return sqrt(pow(a.x - b.x, 2) + pow(a.y - b.y, 2) + pow(a.z - b.z, 2));
    }
    static Vector3 Normalized(Vector3 v) {
        float mag = sqrt(v.x*v.x + v.y*v.y + v.z*v.z);
        if (mag == 0) return Vector3();
        return Vector3(v.x/mag, v.y/mag, v.z/mag);
    }
    Vector3 operator-(const Vector3& other) const {
        return Vector3(x - other.x, y - other.y, z - other.z);
    }
    Vector3 operator+(const Vector3& other) const {
        return Vector3(x + other.x, y + other.y, z + other.z);
    }
    Vector3 operator*(float scalar) const {
        return Vector3(x * scalar, y * scalar, z * scalar);
    }
};

// ============================================================
// MEMORY UTILS
// ============================================================
static uintptr_t baseAddress = 0;

static uintptr_t getBaseAddress() {
    if (baseAddress != 0) return baseAddress;
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && (strstr(name, "UnityFramework") || strstr(name, "FreeFire"))) {
            baseAddress = (uintptr_t)_dyld_get_image_vmaddr_slide(i);
            return baseAddress;
        }
    }
    return 0;
}

static bool readMemory(uintptr_t addr, void *buffer, int len) {
    if (addr == 0) return false;
    vm_size_t size = 0;
    kern_return_t kr = vm_read_overwrite(mach_task_self(), (vm_address_t)addr, len, (vm_address_t)buffer, &size);
    return kr == KERN_SUCCESS && size == len;
}

template <typename T>
static T readAddr(uintptr_t addr) {
    T value = 0;
    if (addr == 0) return value;
    readMemory(addr, &value, sizeof(T));
    return value;
}

// ============================================================
// GET LOCAL PLAYER (cần tìm thêm trong dump.cs)
// ============================================================
static uintptr_t getLocalPlayer() {
    // Tạm thời dùng cách tìm entity gần đúng
    uintptr_t base = getBaseAddress();
    if (base == 0) return 0;
    // Cần tìm offset LocalPlayer trong dump.cs
    return readAddr<uintptr_t>(base + 0x58); // Thử từ GameLogic.mm
}

// ============================================================
// GET ENTITY POSITION
// ============================================================
static Vector3 getEntityPos(uintptr_t entity) {
    Vector3 pos;
    if (entity == 0) return pos;
    pos.x = readAddr<float>(entity + OFFSET_POSITION_X);
    pos.y = readAddr<float>(entity + OFFSET_POSITION_Y);
    pos.z = readAddr<float>(entity + OFFSET_POSITION_Z);
    return pos;
}

static float getEntityHealth(uintptr_t entity) {
    if (entity == 0) return 0;
    return readAddr<float>(entity + 0x1AC); // Tạm dùng từ IMG_0838
}

// ============================================================
// WORLD TO SCREEN
// ============================================================
static bool worldToScreen(Vector3 pos, float *outX, float *outY) {
    uintptr_t base = getBaseAddress();
    float matrix[16];
    
    // Đọc view matrix
    for (int i = 0; i < 16; i++) {
        matrix[i] = readAddr<float>(base + OFFSET_VIEW_MATRIX + i * 4);
    }
    
    float w = matrix[3] * pos.x + matrix[7] * pos.y + matrix[11] * pos.z + matrix[15];
    if (w < 0.01f) return false;
    
    float cx = matrix[0] * pos.x + matrix[4] * pos.y + matrix[8] * pos.z + matrix[12];
    float cy = matrix[1] * pos.x + matrix[5] * pos.y + matrix[9] * pos.z + matrix[13];
    
    float screenWidth = [UIScreen mainScreen].bounds.size.width;
    float screenHeight = [UIScreen mainScreen].bounds.size.height;
    
    *outX = screenWidth / 2 + (cx / w) * screenWidth / 2;
    *outY = screenHeight / 2 - (cy / w) * screenHeight / 2;
    
    return true;
}

// ============================================================
// ESP VIEW
// ============================================================
@interface ESPView : UIView
@end

@implementation ESPView

- (void)drawRect:(CGRect)rect {
    [super drawRect:rect];
    
    uintptr_t base = getBaseAddress();
    if (base == 0) return;
    
    uintptr_t localPlayer = getLocalPlayer();
    if (localPlayer == 0) return;
    
    // Lấy danh sách entity từ HUD
    uintptr_t hudMatch = readAddr<uintptr_t>(base + 0x????); // Cần tìm HUD Match
    if (hudMatch == 0) return;
    
    uintptr_t entityList = readAddr<uintptr_t>(hudMatch + OFFSET_ENTITY_LIST);
    if (entityList == 0) return;
    
    Vector3 playerPos = getEntityPos(localPlayer);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    
    // Đọc danh sách entity (giả định là List<Entity>)
    int count = readAddr<int>(entityList + 0x8); // List.count thường ở +0x8
    uintptr_t items = readAddr<uintptr_t>(entityList + 0x10); // List.items thường ở +0x10
    
    for (int i = 0; i < count && i < 50; i++) {
        uintptr_t entity = readAddr<uintptr_t>(items + i * 8);
        if (entity == 0 || entity == localPlayer) continue;
        
        float health = getEntityHealth(entity);
        if (health <= 0) continue;
        
        Vector3 entityPos = getEntityPos(entity);
        float dist = Vector3::Distance(playerPos, entityPos);
        if (dist > 200) continue;
        
        float screenX, screenY;
        if (!worldToScreen(entityPos, &screenX, &screenY)) continue;
        
        float boxSize = 60.0f / (dist + 0.1f);
        if (boxSize < 5) boxSize = 5;
        if (boxSize > 100) boxSize = 100;
        
        // Vẽ box trắng
        CGContextSetStrokeColorWithColor(ctx, [UIColor whiteColor].CGColor);
        CGContextSetLineWidth(ctx, 1.5);
        CGContextAddRect(ctx, CGRectMake(screenX - boxSize/2, screenY - boxSize, boxSize, boxSize));
        CGContextStrokePath(ctx);
        
        // Vẽ line
        CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithWhite:0.3 alpha:0.6].CGColor);
        CGContextSetLineWidth(ctx, 1.0);
        CGContextMoveToPoint(ctx, screenX, screenY);
        CGContextAddLineToPoint(ctx, screenX, screenY + boxSize * 0.8);
        CGContextStrokePath(ctx);
        
        // Vẽ máu
        float hpPercent = health / 100.0f;
        CGContextSetFillColorWithColor(ctx, [UIColor colorWithWhite:0.1 alpha:0.8].CGColor);
        CGContextFillRect(ctx, CGRectMake(screenX - boxSize/2 - 6, screenY - boxSize - 4, 4, boxSize + 8));
        
        UIColor *hpColor = hpPercent > 0.7 ? [UIColor greenColor] : (hpPercent > 0.3 ? [UIColor yellowColor] : [UIColor redColor]);
        CGContextSetFillColorWithColor(ctx, hpColor.CGColor);
        float hpHeight = boxSize * hpPercent;
        CGContextFillRect(ctx, CGRectMake(screenX - boxSize/2 - 5, screenY - boxSize - 2 + (boxSize - hpHeight), 2, hpHeight));
    }
}
@end

// ============================================================
// MENU
// ============================================================
static UIButton *menuBtn = nil;
static UIView *menuView = nil;
static BOOL menuVisible = NO;
static ESPView *espView = nil;

static void showMenu() {
    UIWindow *window = [UIApplication sharedApplication].keyWindow;
    if (!window || menuVisible) return;
    
    menuView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 280, 200)];
    menuView.center = window.center;
    menuView.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.9];
    menuView.layer.cornerRadius = 16;
    [window addSubview:menuView];
    
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(20, 20, 240, 30)];
    title.text = @"🔥 ESP MENU";
    title.textColor = [UIColor whiteColor];
    title.textAlignment = NSTextAlignmentCenter;
    [menuView addSubview:title];
    
    UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    closeBtn.frame = CGRectMake(80, 140, 120, 40);
    [closeBtn setTitle:@"Close" forState:UIControlStateNormal];
    [closeBtn setTitleColor:[UIColor redColor] forState:UIControlStateNormal];
    [closeBtn addTarget:self action:@selector(closeMenu) forControlEvents:UIControlEventTouchUpInside];
    [menuView addSubview:closeBtn];
    
    menuVisible = YES;
    menuBtn.hidden = YES;
}

static void closeMenu() {
    [menuView removeFromSuperview];
    menuView = nil;
    menuVisible = NO;
    menuBtn.hidden = NO;
}

static void toggleMenu() {
    if (menuVisible) closeMenu();
    else showMenu();
}

// ============================================================
// HOOK
// ============================================================
static void (*orig_viewDidLoad)(id self, SEL _cmd);
static void hooked_viewDidLoad(id self, SEL _cmd) {
    orig_viewDidLoad(self, _cmd);
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1.0 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        UIWindow *window = [UIApplication sharedApplication].keyWindow;
        if (!window) return;
        
        menuBtn = [UIButton buttonWithType:UIButtonTypeCustom];
        menuBtn.frame = CGRectMake(20, 80, 60, 60);
        [menuBtn setTitle:@"⚡" forState:UIControlStateNormal];
        [menuBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        menuBtn.titleLabel.font = [UIFont boldSystemFontOfSize:30];
        menuBtn.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.7];
        menuBtn.layer.cornerRadius = 30;
        [menuBtn addTarget:self action:@selector(toggleMenu) forControlEvents:UIControlEventTouchUpInside];
        [window addSubview:menuBtn];
        
        espView = [[ESPView alloc] initWithFrame:[UIScreen mainScreen].bounds];
        espView.backgroundColor = [UIColor clearColor];
        espView.userInteractionEnabled = NO;
        espView.layer.zPosition = 9999;
        [window addSubview:espView];
        
        [NSTimer scheduledTimerWithTimeInterval:0.05 repeats:YES block:^(NSTimer *timer) {
            [espView setNeedsDisplay];
        }];
    });
}

// ============================================================
// CTOR
// ============================================================
__attribute__((constructor)) static void init() {
    NSLog(@"[UltimateHack] Loaded!");
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2.0 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        Class target = NSClassFromString(@"UnityAppController");
        if (!target) target = NSClassFromString(@"AppController");
        if (!target) target = NSClassFromString(@"GameController");
        if (!target) {
            NSLog(@"[UltimateHack] Không tìm thấy class chính");
            return;
        }
        
        SEL vdl = @selector(viewDidLoad);
        if ([target instancesRespondToSelector:vdl]) {
            orig_viewDidLoad = (void *)class_getMethodImplementation(target, vdl);
            Method m = class_getInstanceMethod(target, vdl);
            if (m) method_setImplementation(m, (IMP)hooked_viewDidLoad);
        }
        
        NSLog(@"[UltimateHack] Hooked %s", class_getName(target));
    });
}
