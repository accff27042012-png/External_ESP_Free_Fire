#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#include <mach/mach.h>
#include <math.h>
#include <sys/sysctl.h>

// ============================================================
// OFFSET (CŨ - CÓ THỂ KHÔNG CHÍNH XÁC)
// ============================================================
#define OFFSET_LOCAL_PLAYER        0xB8
#define OFFSET_ENTITY_LIST         0x440
#define OFFSET_PLAYER_LIST         0x450
#define OFFSET_VIEW_MATRIX         0x1B0
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
static bool espEnabled = YES;
static bool wallHackEnabled = YES;
static bool aimbotEnabled = YES;
static int aimbotMode = 0; // 0: Luôn aim, 1: Khi bắn, 2: Khi ngắm
static float aimFov = 30.0f;
static bool isFiring = NO;
static bool isAiming = NO;

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
// AIMBOT
// ============================================================
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
        
        // Check wall (nếu bật)
        if (!wallHackEnabled) {
            // Kiểm tra vật cản (bỏ qua)
        }
        
        Vector3 entityPos = getEntityPos(entity);
        float dist = Vector3::Distance(playerPos, entityPos);
        if (dist > 200) continue;
        
        float angleToTarget = 45.0f;
        
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
        
        // BOX TRẮNG
        CGContextSetStrokeColorWithColor(ctx, [UIColor whiteColor].CGColor);
        CGContextSetLineWidth(ctx, 2.0);
        CGContextAddRect(ctx, CGRectMake(screenX - boxSize/2, screenY - boxSize, boxSize, boxSize));
        CGContextStrokePath(ctx);
        
        // LINE
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
// MENU
// ============================================================
static UIButton *menuBtn = nil;
static UIView *menuView = nil;
static BOOL menuVisible = NO;
static BOOL menuMinimized = NO;
static ESPView *espView = nil;
static BOOL menuCreated = NO;

static void toggleESP(UISwitch *sender) { espEnabled = sender.isOn; }
static void toggleWallhack(UISwitch *sender) { wallHackEnabled = sender.isOn; }
static void toggleAimbot(UISwitch *sender) { aimbotEnabled = sender.isOn; }

static void fovChanged(UISlider *slider) {
    aimFov = slider.value;
    UILabel *fovValueLabel = (UILabel *)[slider.superview viewWithTag:999];
    if (fovValueLabel) {
        fovValueLabel.text = [NSString stringWithFormat:@"%.0f°", aimFov];
    }
}

static void aimModeChanged(UISegmentedControl *seg) {
    aimbotMode = (int)seg.selectedSegmentIndex;
}

static void closeMenu() {
    if (menuView) {
        [UIView animateWithDuration:0.3 animations:^{
            menuView.transform = CGAffineTransformMakeScale(0.01, 0.01);
            menuView.alpha = 0.0;
        } completion:^(BOOL finished) {
            [menuView removeFromSuperview];
            menuView = nil;
            menuVisible = NO;
            menuMinimized = NO;
            menuBtn.hidden = NO;
        }];
    }
}

static void minimizeMenu() {
    if (menuView) {
        menuMinimized = !menuMinimized;
        if (menuMinimized) {
            [UIView animateWithDuration:0.3 animations:^{
                menuView.frame = CGRectMake(0, 0, 60, 60);
                menuView.layer.cornerRadius = 30;
            }];
        } else {
            [UIView animateWithDuration:0.3 animations:^{
                menuView.frame = CGRectMake(0, 0, 320, 460);
                menuView.layer.cornerRadius = 0;
            }];
        }
    }
}

static void showMenu() {
    UIWindow *window = [UIApplication sharedApplication].keyWindow;
    if (!window || menuVisible) return;
    
    menuView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 320, 460)];
    menuView.center = window.center;
    menuView.backgroundColor = [UIColor colorWithWhite:0.05 alpha:0.95];
    menuView.layer.cornerRadius = 16;
    menuView.layer.borderColor = [UIColor colorWithRed:218/255.0 green:37/255.0 blue:28/255.0 alpha:1.0].CGColor;
    menuView.layer.borderWidth = 2;
    menuView.userInteractionEnabled = YES;
    [window addSubview:menuView];
    [window bringSubviewToFront:menuView];
    
    // Title Bar
    UIView *titleBar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 320, 44)];
    titleBar.backgroundColor = [UIColor colorWithWhite:0.1 alpha:1.0];
    titleBar.layer.cornerRadius = 16;
    titleBar.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner;
    titleBar.userInteractionEnabled = YES;
    [menuView addSubview:titleBar];
    
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(20, 10, 200, 24)];
    title.text = @"🇻🇳 HungVn Hack";
    title.textColor = [UIColor whiteColor];
    title.font = [UIFont boldSystemFontOfSize:16];
    [titleBar addSubview:title];
    
    UIButton *minimizeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    minimizeBtn.frame = CGRectMake(260, 10, 24, 24);
    [minimizeBtn setTitle:@"-" forState:UIControlStateNormal];
    [minimizeBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    minimizeBtn.titleLabel.font = [UIFont boldSystemFontOfSize:20];
    minimizeBtn.userInteractionEnabled = YES;
    [minimizeBtn addTarget:nil action:@selector(minimizeMenu) forControlEvents:UIControlEventTouchUpInside];
    [titleBar addSubview:minimizeBtn];
    
    UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    closeBtn.frame = CGRectMake(290, 10, 24, 24);
    [closeBtn setTitle:@"✕" forState:UIControlStateNormal];
    [closeBtn setTitleColor:[UIColor redColor] forState:UIControlStateNormal];
    closeBtn.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    closeBtn.userInteractionEnabled = YES;
    [closeBtn addTarget:nil action:@selector(closeMenu) forControlEvents:UIControlEventTouchUpInside];
    [titleBar addSubview:closeBtn];
    
    int yOffset = 54;
    int step = 44;
    
    // ESP
    UISwitch *espSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(230, yOffset, 50, 30)];
    espSwitch.onTintColor = [UIColor colorWithRed:218/255.0 green:37/255.0 blue:28/255.0 alpha:1.0];
    espSwitch.thumbTintColor = [UIColor colorWithRed:255/255.0 green:255/255.0 blue:0/255.0 alpha:1.0];
    espSwitch.userInteractionEnabled = YES;
    [espSwitch setOn:espEnabled];
    [espSwitch addTarget:nil action:@selector(toggleESP:) forControlEvents:UIControlEventValueChanged];
    [menuView addSubview:espSwitch];
    
    UILabel *espLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, yOffset, 160, 30)];
    espLabel.text = @"👁 ESP";
    espLabel.textColor = [UIColor whiteColor];
    espLabel.font = [UIFont systemFontOfSize:15];
    [menuView addSubview:espLabel];
    yOffset += step;
    
    // Wall
    UISwitch *whSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(230, yOffset, 50, 30)];
    whSwitch.onTintColor = [UIColor colorWithRed:218/255.0 green:37/255.0 blue:28/255.0 alpha:1.0];
    whSwitch.thumbTintColor = [UIColor colorWithRed:255/255.0 green:255/255.0 blue:0/255.0 alpha:1.0];
    whSwitch.userInteractionEnabled = YES;
    [whSwitch setOn:wallHackEnabled];
    [whSwitch addTarget:nil action:@selector(toggleWallhack:) forControlEvents:UIControlEventValueChanged];
    [menuView addSubview:whSwitch];
    
    UILabel *whLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, yOffset, 160, 30)];
    whLabel.text = @"🧱 Wall Hack";
    whLabel.textColor = [UIColor whiteColor];
    whLabel.font = [UIFont systemFontOfSize:15];
    [menuView addSubview:whLabel];
    yOffset += step;
    
    // Aimbot
    UISwitch *aimSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(230, yOffset, 50, 30)];
    aimSwitch.onTintColor = [UIColor colorWithRed:218/255.0 green:37/255.0 blue:28/255.0 alpha:1.0];
    aimSwitch.thumbTintColor = [UIColor colorWithRed:255/255.0 green:255/255.0 blue:0/255.0 alpha:1.0];
    aimSwitch.userInteractionEnabled = YES;
    [aimSwitch setOn:aimbotEnabled];
    [aimSwitch addTarget:nil action:@selector(toggleAimbot:) forControlEvents:UIControlEventValueChanged];
    [menuView addSubview:aimSwitch];
    
    UILabel *aimLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, yOffset, 160, 30)];
    aimLabel.text = @"🎯 Aimbot";
    aimLabel.textColor = [UIColor whiteColor];
    aimLabel.font = [UIFont systemFontOfSize:15];
    [menuView addSubview:aimLabel];
    yOffset += step;
    
    // Aim Mode
    UILabel *modeLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, yOffset, 160, 30)];
    modeLabel.text = @"Aim Mode:";
    modeLabel.textColor = [UIColor whiteColor];
    modeLabel.font = [UIFont systemFontOfSize:15];
    [menuView addSubview:modeLabel];
    
    UISegmentedControl *modeSeg = [[UISegmentedControl alloc] initWithFrame:CGRectMake(20, yOffset + 30, 280, 30)];
    [modeSeg insertSegmentWithTitle:@"Luôn" atIndex:0 animated:NO];
    [modeSeg insertSegmentWithTitle:@"Bắn" atIndex:1 animated:NO];
    [modeSeg insertSegmentWithTitle:@"Ngắm" atIndex:2 animated:NO];
    modeSeg.selectedSegmentIndex = aimbotMode;
    modeSeg.tintColor = [UIColor colorWithRed:218/255.0 green:37/255.0 blue:28/255.0 alpha:1.0];
    modeSeg.userInteractionEnabled = YES;
    [modeSeg addTarget:nil action:@selector(aimModeChanged:) forControlEvents:UIControlEventValueChanged];
    [menuView addSubview:modeSeg];
    yOffset += 70;
    
    // FOV
    UILabel *fovLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, yOffset, 100, 30)];
    fovLabel.text = @"FOV:";
    fovLabel.textColor = [UIColor whiteColor];
    fovLabel.font = [UIFont systemFontOfSize:15];
    [menuView addSubview:fovLabel];
    
    UILabel *fovValueLabel = [[UILabel alloc] initWithFrame:CGRectMake(220, yOffset, 80, 30)];
    fovValueLabel.text = [NSString stringWithFormat:@"%.0f°", aimFov];
    fovValueLabel.textColor = [UIColor colorWithRed:255/255.0 green:255/255.0 blue:0/255.0 alpha:1.0];
    fovValueLabel.font = [UIFont systemFontOfSize:15];
    fovValueLabel.tag = 999;
    [menuView addSubview:fovValueLabel];
    yOffset += 30;
    
    UISlider *fovSlider = [[UISlider alloc] initWithFrame:CGRectMake(20, yOffset, 280, 30)];
    fovSlider.minimumValue = 10.0f;
    fovSlider.maximumValue = 120.0f;
    fovSlider.value = aimFov;
    fovSlider.minimumTrackTintColor = [UIColor colorWithRed:218/255.0 green:37/255.0 blue:28/255.0 alpha:1.0];
    fovSlider.maximumTrackTintColor = [UIColor grayColor];
    fovSlider.userInteractionEnabled = YES;
    [fovSlider addTarget:nil action:@selector(fovChanged:) forControlEvents:UIControlEventValueChanged];
    fovSlider.tag = 998;
    [menuView addSubview:fovSlider];
    
    menuVisible = YES;
    menuBtn.hidden = YES;
}

static void toggleMenu() {
    if (menuVisible) {
        closeMenu();
    } else {
        showMenu();
    }
}

// ============================================================
// HÀM TẠO MENU (LUÔN HIỆN)
// ============================================================
static void createMenuOnWindow(UIWindow *window) {
    if (!window) return;
    if (menuBtn) return;
    if (menuCreated) return;
    
    menuCreated = YES;
    
    menuBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    menuBtn.frame = CGRectMake(20, 80, 60, 60);
    [menuBtn setTitle:@"🇻🇳" forState:UIControlStateNormal];
    [menuBtn setTitleColor:[UIColor colorWithRed:218/255.0 green:37/255.0 blue:28/255.0 alpha:1.0] forState:UIControlStateNormal];
    menuBtn.titleLabel.font = [UIFont boldSystemFontOfSize:32];
    menuBtn.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.8];
    menuBtn.layer.cornerRadius = 30;
    menuBtn.layer.borderColor = [UIColor colorWithRed:218/255.0 green:37/255.0 blue:28/255.0 alpha:1.0].CGColor;
    menuBtn.layer.borderWidth = 2;
    menuBtn.userInteractionEnabled = YES;
    [menuBtn addTarget:nil action:@selector(toggleMenu) forControlEvents:UIControlEventTouchUpInside];
    [window addSubview:menuBtn];
    [window bringSubviewToFront:menuBtn];
    
    espView = [[ESPView alloc] initWithFrame:[UIScreen mainScreen].bounds];
    espView.backgroundColor = [UIColor clearColor];
    espView.userInteractionEnabled = NO;
    espView.layer.zPosition = 9999;
    [window addSubview:espView];
    [window bringSubviewToFront:espView];
    
    [NSTimer scheduledTimerWithTimeInterval:0.05 repeats:YES block:^(NSTimer *timer) {
        [espView setNeedsDisplay];
    }];
    
    NSLog(@"[HungVn] Menu created!");
}

// ============================================================
// HOOK UIApplication
// ============================================================
static IMP orig_sendEvent = NULL;

static void hooked_sendEvent(id self, SEL _cmd, UIEvent *event) {
    static BOOL firstRun = NO;
    if (!firstRun) {
        firstRun = YES;
        dispatch_async(dispatch_get_main_queue(), ^{
            UIWindow *window = [UIApplication sharedApplication].keyWindow;
            if (window) {
                createMenuOnWindow(window);
            } else {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2.0 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                    UIWindow *window2 = [UIApplication sharedApplication].keyWindow;
                    if (window2) createMenuOnWindow(window2);
                });
            }
        });
    }
    ((void (*)(id, SEL, UIEvent *))orig_sendEvent)(self, _cmd, event);
}

// ============================================================
// CTOR
// ============================================================
__attribute__((constructor)) static void init() {
    NSLog(@"[HungVn] Dylib loaded!");
    
    Class UIApplicationClass = objc_getClass("UIApplication");
    if (UIApplicationClass) {
        SEL sendEvent = @selector(sendEvent:);
        Method m = class_getInstanceMethod(UIApplicationClass, sendEvent);
        if (m) {
            orig_sendEvent = method_getImplementation(m);
            method_setImplementation(m, (IMP)hooked_sendEvent);
            NSLog(@"[HungVn] Hooked UIApplication sendEvent!");
        }
    }
}
