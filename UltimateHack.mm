#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#include <mach/mach.h>
#include <math.h>
#include <sys/sysctl.h>

// ============================================================
// OFFSET TỔNG HỢP TỪ DUMP.CS
// ============================================================
#define OFFSET_LOCAL_PLAYER        0xB8
#define OFFSET_CAMERA              0x108
#define OFFSET_VIEW_MATRIX         0x1B0
#define OFFSET_ENTITY_LIST         0x440
#define OFFSET_PLAYER_LIST         0x450
#define OFFSET_POSITION_X          0xC8
#define OFFSET_POSITION_Y          0xC4
#define OFFSET_POSITION_Z          0xD0
#define OFFSET_IS_LOCAL_PLAYER     0xD1
#define OFFSET_HEALTH              0x1AC
#define OFFSET_TEAM                0x1B0
#define OFFSET_VIEW_ANGLE          0x1B8

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
static bool aimbotEnabled = YES;
static bool espEnabled = YES;
static float aimFov = 30.0f;

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

static void writeAddr(uintptr_t addr, float value) {
    if (addr == 0) return;
    vm_protect(mach_task_self(), (vm_address_t)addr, sizeof(float), 0, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    *(float *)addr = value;
}

// ============================================================
// LẤY LOCAL PLAYER
// ============================================================
static uintptr_t getLocalPlayer() {
    uintptr_t base = getBaseAddress();
    if (base == 0) return 0;
    
    uintptr_t entityList = readAddr<uintptr_t>(base + OFFSET_ENTITY_LIST);
    if (entityList != 0) {
        int count = readAddr<int>(entityList + 0x8);
        uintptr_t items = readAddr<uintptr_t>(entityList + 0x10);
        for (int i = 0; i < count && i < 100; i++) {
            uintptr_t entity = readAddr<uintptr_t>(items + i * 8);
            if (entity == 0) continue;
            bool isLocal = readAddr<bool>(entity + OFFSET_IS_LOCAL_PLAYER);
            if (isLocal) return entity;
        }
    }
    
    uintptr_t playerList = readAddr<uintptr_t>(base + OFFSET_PLAYER_LIST);
    if (playerList != 0) {
        int count = readAddr<int>(playerList + 0x8);
        uintptr_t items = readAddr<uintptr_t>(playerList + 0x10);
        for (int i = 0; i < count && i < 100; i++) {
            uintptr_t player = readAddr<uintptr_t>(items + i * 8);
            if (player == 0) continue;
            bool isLocal = readAddr<bool>(player + OFFSET_IS_LOCAL_PLAYER);
            if (isLocal) return player;
        }
    }
    
    return 0;
}

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
    return readAddr<float>(entity + OFFSET_HEALTH);
}

static int getEntityTeam(uintptr_t entity) {
    if (entity == 0) return -1;
    return readAddr<int>(entity + OFFSET_TEAM);
}

// ============================================================
// WORLD TO SCREEN
// ============================================================
static bool worldToScreen(Vector3 pos, float *outX, float *outY) {
    uintptr_t base = getBaseAddress();
    float matrix[16];
    
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
    
    return YES;
}

// ============================================================
// AIMBOT + FOV
// ============================================================
static Vector3 getBonePosition(uintptr_t entity, int boneOffset) {
    Vector3 pos = getEntityPos(entity);
    pos.y += 1.8f;
    return pos;
}

static void aimAt(Vector3 target) {
    uintptr_t player = getLocalPlayer();
    if (player == 0) return;
    
    Vector3 pos = getEntityPos(player);
    float dx = target.x - pos.x;
    float dy = target.y - pos.y;
    float dz = target.z - pos.z;
    
    float yaw = atan2(dz, dx) * 180.0f / M_PI - 90.0f;
    float pitch = atan2(dy, sqrt(dx*dx + dz*dz)) * 180.0f / M_PI;
    
    uintptr_t base = getBaseAddress();
    writeAddr(base + OFFSET_VIEW_ANGLE, yaw);
    writeAddr(base + OFFSET_VIEW_ANGLE + 4, pitch);
}

static uintptr_t getBestTarget() {
    uintptr_t player = getLocalPlayer();
    if (player == 0) return 0;
    
    uintptr_t base = getBaseAddress();
    uintptr_t entityList = readAddr<uintptr_t>(base + OFFSET_ENTITY_LIST);
    if (entityList == 0) return 0;
    
    Vector3 playerPos = getEntityPos(player);
    int myTeam = getEntityTeam(player);
    
    uintptr_t bestTarget = 0;
    float bestDist = 9999.0f;
    
    int count = readAddr<int>(entityList + 0x8);
    uintptr_t items = readAddr<uintptr_t>(entityList + 0x10);
    
    for (int i = 0; i < count && i < 100; i++) {
        uintptr_t entity = readAddr<uintptr_t>(items + i * 8);
        if (entity == 0 || entity == player) continue;
        
        float health = getEntityHealth(entity);
        if (health <= 0) continue;
        
        int team = getEntityTeam(entity);
        if (team == myTeam) continue;
        
        Vector3 entityPos = getEntityPos(entity);
        float dist = Vector3::Distance(playerPos, entityPos);
        if (dist > 200) continue;
        
        // Tính FOV
        float angleToTarget = 45.0f; // Giá trị tạm, thay bằng tính toán thực tế
        
        if (angleToTarget < aimFov && dist < bestDist) {
            bestDist = dist;
            bestTarget = entity;
        }
    }
    
    return bestTarget;
}

// ============================================================
// ESP VIEW
// ============================================================
@interface ESPView : UIView
@end

@implementation ESPView

- (void)drawRect:(CGRect)rect {
    [super drawRect:rect];
    if (!espEnabled) return;
    
    uintptr_t player = getLocalPlayer();
    if (player == 0) return;
    
    uintptr_t base = getBaseAddress();
    uintptr_t entityList = readAddr<uintptr_t>(base + OFFSET_ENTITY_LIST);
    if (entityList == 0) return;
    
    Vector3 playerPos = getEntityPos(player);
    int myTeam = getEntityTeam(player);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    
    int count = readAddr<int>(entityList + 0x8);
    uintptr_t items = readAddr<uintptr_t>(entityList + 0x10);
    
    for (int i = 0; i < count && i < 100; i++) {
        uintptr_t entity = readAddr<uintptr_t>(items + i * 8);
        if (entity == 0 || entity == player) continue;
        
        float health = getEntityHealth(entity);
        if (health <= 0) continue;
        
        int team = getEntityTeam(entity);
        if (team == myTeam) continue;
        
        Vector3 entityPos = getEntityPos(entity);
        float dist = Vector3::Distance(playerPos, entityPos);
        if (dist > 200) continue;
        
        float screenX, screenY;
        if (!worldToScreen(entityPos, &screenX, &screenY)) continue;
        
        float boxSize = 60.0f / (dist + 0.1f);
        if (boxSize < 5) boxSize = 5;
        if (boxSize > 100) boxSize = 100;
        
        // BOX TRẮNG TINH
        CGContextSetStrokeColorWithColor(ctx, [UIColor whiteColor].CGColor);
        CGContextSetLineWidth(ctx, 2.0);
        CGContextAddRect(ctx, CGRectMake(screenX - boxSize/2, screenY - boxSize, boxSize, boxSize));
        CGContextStrokePath(ctx);
        
        // LINE TRẮNG MỜ
        CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithWhite:0.5 alpha:0.5].CGColor);
        CGContextSetLineWidth(ctx, 1.0);
        CGContextMoveToPoint(ctx, screenX, screenY);
        CGContextAddLineToPoint(ctx, screenX, screenY + boxSize * 0.8);
        CGContextStrokePath(ctx);
        
        // HEALTH BAR
        float hpPercent = health / 100.0f;
        if (hpPercent < 0) hpPercent = 0;
        if (hpPercent > 1) hpPercent = 1;
        
        CGContextSetFillColorWithColor(ctx, [UIColor colorWithWhite:0.15 alpha:0.8].CGColor);
        CGContextFillRect(ctx, CGRectMake(screenX - boxSize/2 - 6, screenY - boxSize - 4, 4, boxSize + 8));
        
        UIColor *hpColor = hpPercent > 0.7 ? [UIColor greenColor] : 
                           (hpPercent > 0.3 ? [UIColor yellowColor] : [UIColor redColor]);
        CGContextSetFillColorWithColor(ctx, hpColor.CGColor);
        float hpHeight = boxSize * hpPercent;
        CGContextFillRect(ctx, CGRectMake(screenX - boxSize/2 - 5, screenY - boxSize - 2 + (boxSize - hpHeight), 2, hpHeight));
        
        // DISTANCE
        NSString *distStr = [NSString stringWithFormat:@"%.0fm", dist];
        NSDictionary *attrs = @{
            NSFontAttributeName: [UIFont boldSystemFontOfSize:10],
            NSForegroundColorAttributeName: [UIColor whiteColor],
            NSStrokeColorAttributeName: [UIColor blackColor],
            NSStrokeWidthAttributeName: @(-2.0)
        };
        CGSize size = [distStr sizeWithAttributes:attrs];
        [distStr drawAtPoint:CGPointMake(screenX - size.width/2, screenY + boxSize + 4) withAttributes:attrs];
    }
}
@end

// ============================================================
// MENU HUNGVN - HÌNH TRÒN + FOV SLIDER
// ============================================================
static UIButton *menuBtn = nil;
static UIView *menuView = nil;
static BOOL menuVisible = NO;
static ESPView *espView = nil;

static void toggleESP(UISwitch *sender) { espEnabled = sender.isOn; }
static void toggleAimbot(UISwitch *sender) { aimbotEnabled = sender.isOn; }

static void fovChanged(UISlider *slider) {
    aimFov = slider.value;
    UILabel *fovValueLabel = (UILabel *)[slider.superview viewWithTag:999];
    if (fovValueLabel) {
        fovValueLabel.text = [NSString stringWithFormat:@"%.0f°", aimFov];
    }
}

static void closeMenu() {
    [UIView animateWithDuration:0.3 animations:^{
        menuView.transform = CGAffineTransformMakeScale(0.01, 0.01);
        menuView.alpha = 0.0;
    } completion:^(BOOL finished) {
        [menuView removeFromSuperview];
        menuView = nil;
        menuVisible = NO;
        menuBtn.hidden = NO;
    }];
}

static void showMenu() {
    UIWindow *window = [UIApplication sharedApplication].keyWindow;
    if (!window || menuVisible) return;
    
    // Menu hình tròn
    menuView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 280, 340)];
    menuView.center = window.center;
    menuView.backgroundColor = [UIColor colorWithWhite:0.05 alpha:0.95];
    menuView.layer.cornerRadius = 140;
    menuView.layer.borderColor = [UIColor colorWithRed:218/255.0 green:37/255.0 blue:28/255.0 alpha:1.0].CGColor;
    menuView.layer.borderWidth = 3;
    [window addSubview:menuView];
    
    // Icon trung tâm - Cờ Việt Nam
    UILabel *centerIcon = [[UILabel alloc] initWithFrame:CGRectMake(0, 8, 280, 50)];
    centerIcon.text = @"🇻🇳";
    centerIcon.font = [UIFont systemFontOfSize:50];
    centerIcon.textAlignment = NSTextAlignmentCenter;
    [menuView addSubview:centerIcon];
    
    // Tên hack
    UILabel *nameLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 56, 280, 24)];
    nameLabel.text = @"HungVn";
    nameLabel.textColor = [UIColor colorWithRed:218/255.0 green:37/255.0 blue:28/255.0 alpha:1.0];
    nameLabel.font = [UIFont boldSystemFontOfSize:20];
    nameLabel.textAlignment = NSTextAlignmentCenter;
    [menuView addSubview:nameLabel];
    
    // Credit
    UILabel *creditLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 78, 280, 14)];
    creditLabel.text = @"made by HungDz";
    creditLabel.textColor = [UIColor colorWithRed:255/255.0 green:255/255.0 blue:0/255.0 alpha:0.8];
    creditLabel.font = [UIFont systemFontOfSize:11];
    creditLabel.textAlignment = NSTextAlignmentCenter;
    [menuView addSubview:creditLabel];
    
    // ESP Switch
    UISwitch *espSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(190, 110, 50, 30)];
    espSwitch.onTintColor = [UIColor colorWithRed:218/255.0 green:37/255.0 blue:28/255.0 alpha:1.0];
    espSwitch.thumbTintColor = [UIColor colorWithRed:255/255.0 green:255/255.0 blue:0/255.0 alpha:1.0];
    [espSwitch setOn:espEnabled];
    [espSwitch addTarget:nil action:@selector(toggleESP:) forControlEvents:UIControlEventValueChanged];
    [menuView addSubview:espSwitch];
    
    UILabel *espLabel = [[UILabel alloc] initWithFrame:CGRectMake(30, 110, 150, 30)];
    espLabel.text = @"🇻🇳 ESP";
    espLabel.textColor = [UIColor whiteColor];
    espLabel.font = [UIFont systemFontOfSize:15];
    [menuView addSubview:espLabel];
    
    // Aimbot Switch
    UISwitch *aimSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(190, 150, 50, 30)];
    aimSwitch.onTintColor = [UIColor colorWithRed:218/255.0 green:37/255.0 blue:28/255.0 alpha:1.0];
    aimSwitch.thumbTintColor = [UIColor colorWithRed:255/255.0 green:255/255.0 blue:0/255.0 alpha:1.0];
    [aimSwitch setOn:aimbotEnabled];
    [aimSwitch addTarget:nil action:@selector(toggleAimbot:) forControlEvents:UIControlEventValueChanged];
    [menuView addSubview:aimSwitch];
    
    UILabel *aimLabel = [[UILabel alloc] initWithFrame:CGRectMake(30, 150, 150, 30)];
    aimLabel.text = @"🇻🇳 Aimbot";
    aimLabel.textColor = [UIColor whiteColor];
    aimLabel.font = [UIFont systemFontOfSize:15];
    [menuView addSubview:aimLabel];
    
    // FOV Label + Slider
    UILabel *fovLabel = [[UILabel alloc] initWithFrame:CGRectMake(30, 190, 100, 30)];
    fovLabel.text = @"FOV:";
    fovLabel.textColor = [UIColor whiteColor];
    fovLabel.font = [UIFont systemFontOfSize:15];
    [menuView addSubview:fovLabel];
    
    UILabel *fovValueLabel = [[UILabel alloc] initWithFrame:CGRectMake(190, 190, 60, 30)];
    fovValueLabel.text = [NSString stringWithFormat:@"%.0f°", aimFov];
    fovValueLabel.textColor = [UIColor colorWithRed:255/255.0 green:255/255.0 blue:0/255.0 alpha:1.0];
    fovValueLabel.font = [UIFont systemFontOfSize:15];
    fovValueLabel.tag = 999;
    [menuView addSubview:fovValueLabel];
    
    UISlider *fovSlider = [[UISlider alloc] initWithFrame:CGRectMake(30, 220, 220, 30)];
    fovSlider.minimumValue = 10.0f;
    fovSlider.maximumValue = 120.0f;
    fovSlider.value = aimFov;
    fovSlider.minimumTrackTintColor = [UIColor colorWithRed:218/255.0 green:37/255.0 blue:28/255.0 alpha:1.0];
    fovSlider.maximumTrackTintColor = [UIColor grayColor];
    [fovSlider addTarget:nil action:@selector(fovChanged:) forControlEvents:UIControlEventValueChanged];
    fovSlider.tag = 998;
    [menuView addSubview:fovSlider];
    
    // Close
    UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    closeBtn.frame = CGRectMake(90, 265, 100, 30);
    [closeBtn setTitle:@"🇻🇳" forState:UIControlStateNormal];
    [closeBtn setTitleColor:[UIColor colorWithRed:255/255.0 green:255/255.0 blue:0/255.0 alpha:1.0] forState:UIControlStateNormal];
    closeBtn.titleLabel.font = [UIFont boldSystemFontOfSize:20];
    [closeBtn addTarget:nil action:@selector(closeMenu) forControlEvents:UIControlEventTouchUpInside];
    [menuView addSubview:closeBtn];
    
    menuVisible = YES;
    menuBtn.hidden = YES;
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
        [menuBtn setTitle:@"🇻🇳" forState:UIControlStateNormal];
        [menuBtn setTitleColor:[UIColor colorWithRed:218/255.0 green:37/255.0 blue:28/255.0 alpha:1.0] forState:UIControlStateNormal];
        menuBtn.titleLabel.font = [UIFont boldSystemFontOfSize:32];
        menuBtn.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.8];
        menuBtn.layer.cornerRadius = 30;
        menuBtn.layer.borderColor = [UIColor colorWithRed:218/255.0 green:37/255.0 blue:28/255.0 alpha:1.0].CGColor;
        menuBtn.layer.borderWidth = 2;
        [menuBtn addTarget:nil action:@selector(toggleMenu) forControlEvents:UIControlEventTouchUpInside];
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

static void (*orig_update)(id self, SEL _cmd, id sender);
static void hooked_update(id self, SEL _cmd, id sender) {
    orig_update(self, _cmd, sender);
    if (!aimbotEnabled) return;
    
    uintptr_t target = getBestTarget();
    if (target != 0) {
        Vector3 headPos = getEntityPos(target);
        headPos.y += 1.8f;
        aimAt(headPos);
    }
}

// ============================================================
// CTOR
// ============================================================
__attribute__((constructor)) static void init() {
    NSLog(@"[HungVn] Loaded!");
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2.0 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        Class target = NSClassFromString(@"UnityAppController");
        if (!target) target = NSClassFromString(@"AppController");
        if (!target) target = NSClassFromString(@"GameController");
        if (!target) {
            NSLog(@"[HungVn] Không tìm thấy class chính");
            return;
        }
        
        SEL vdl = @selector(viewDidLoad);
        if ([target instancesRespondToSelector:vdl]) {
            orig_viewDidLoad = (IMP)class_getMethodImplementation(target, vdl);
            Method m = class_getInstanceMethod(target, vdl);
            if (m) method_setImplementation(m, (IMP)hooked_viewDidLoad);
        }
        
        SEL up = @selector(update:);
        if ([target instancesRespondToSelector:up]) {
            orig_update = (IMP)class_getMethodImplementation(target, up);
            Method m = class_getInstanceMethod(target, up);
            if (m) method_setImplementation(m, (IMP)hooked_update);
        }
        
        NSLog(@"[HungVn] Hooked %s", class_getName(target));
    });
}
