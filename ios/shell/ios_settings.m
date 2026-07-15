// ios_settings.m — the in-app iOS settings sheet (charter Phase 2 item,
// scoped per Austin's direction: gyro aim, FPS counter, touch look
// sensitivity, refresh rate). Long-press the ≡ button to open.
//
// These are SHELL settings (NSUserDefaults), deliberately not engine
// cvars: they configure the iOS layer itself. Engine-side options keep
// living in the stock SETUP menus.

#import <UIKit/UIKit.h>
#import "ios_settings.h"

// appliers (ios_input.m / AppShell.m)
void Q3E_Input_SetGyro(int enabled, float scale);
void Q3E_Input_SetTouchSens(float sx, float sy);
void Q3E_Input_SetControlStyle(float scale, float alpha, int lefty);
void Q3E_Shell_SetRefreshMode(int mode60);  // 0 = native/120, 1 = 60
void Q3E_Shell_SetFPSCounter(int enabled);
void Q3E_Input_SetFireHaptics(int on);       // haptic tap on fire (ios_input.m)
void Q3E_QueueCommand(const char *cmd);      // push a console command to the engine
#if TARGET_OS_VISION
void  VK_Set3DSeparation(float sep);         // stereo parallax divisor (renderervk 0006)
void  Q3E_Set3DPanel(float dist, float halfW); // 3D screen distance/size (Q3EImmersive.m)
void  Q3E_Set3DHeight(float h);              // 3D screen height + auto-tilt
void  Q3E_Set3DHideGun(int on);              // hide the weapon in 3D (AppShell_vision.m)
void  Q3E_Set3DHideHead(int on);             // flatten the HUD 3D head in 3D
void  Q3E_Set3DDim(float d);                 // surroundings dimming (Q3EImmersive.m)
#endif

#define DEF_GYRO_ON     @"q3e_gyro_on"
#define DEF_GYRO_SCALE  @"q3e_gyro_scale"
#define DEF_TOUCH_SENS  @"q3e_touch_sens" // legacy single-axis key
#define DEF_SENS_X      @"q3e_sens_x"
#define DEF_SENS_Y      @"q3e_sens_y"
#define DEF_CTL_SCALE   @"q3e_ctl_scale"
#define DEF_CTL_ALPHA   @"q3e_ctl_alpha"
#define DEF_LEFTY       @"q3e_lefty"
#define DEF_REFRESH_60  @"q3e_refresh_60"
#define DEF_FPS_COUNTER @"q3e_fps_counter"
#define DEF_INVERT      @"q3e_invert_look"
#define DEF_FIRE_HAPTIC @"q3e_fire_haptic"
#define DEF_SND_VOL     @"q3e_snd_vol"
#define DEF_MUS_VOL     @"q3e_mus_vol"
#define DEF_MSAA        @"q3e_msaa"
#define DEF_XHAIR_SIZE  @"q3e_xhair_size"
#define DEF_XHAIR_STYLE @"q3e_xhair_style"
#define DEF_FOV         @"q3e_fov"
#define DEF_BRIGHTNESS  @"q3e_brightness"
#define DEF_ALWAYS_RUN  @"q3e_always_run"
#define DEF_AUTOSWITCH  @"q3e_autoswitch"
#define DEF_SIMPLEITEMS @"q3e_simpleitems"
#define DEF_HIDEGUN_3D  @"q3e_hidegun_3d"
#define DEF_HIDEHEAD_3D @"q3e_hidehead_3d"
#define DEF_DEPTH_3D    @"q3e_depth_3d"     // depth multiplier (higher = more parallax)
#define DEF_DIST_3D     @"q3e_dist_3d"      // panel distance (m)
#define DEF_SIZE_3D     @"q3e_size_3d"      // panel half-width (m)
#define DEF_HEIGHT_3D   @"q3e_height_3d"    // panel height above eye (m, + auto-tilt)
#define DEF_UNITS_FT    @"q3e_units_ft"     // display panel measurements in feet
#define DEF_FOCUS_3D    @"q3e_focus_3d"     // stereo convergence plane (r_zproj, game units)
#define DEF_DIM_3D      @"q3e_dim_3d"       // surroundings dimming (0..1, perceptual curve)

// Stereo depth default/range (Austin, on-device): the old slider's 40% floor was the
// comfortable value and 140%+ was overbearing — and the numbers are an arbitrary
// parallax divisor, not calibrated to IPD (physical disparity also depends on the
// user-adjustable panel size/distance), so the scale is ours to define. The slider
// spans 0.1–1.0. Default 60%: after both-eyes-per-frame landed (D-022) Austin found
// higher depth comfortable — much of the old strain was alternation judder itself.
#define Q3E_DEPTH_DEFAULT 0.6f

// Crosshair distance (stereo convergence): r_zproj is the world depth that renders at
// ZERO parallax — i.e. exactly at the panel plane, where the 2D crosshair/HUD live. At
// the upstream 64 the crosshair's apparent depth matches objects only ~1.6 m into the
// scene, closer than most combat; raising it pushes the focus plane out to where
// enemies actually are (vkQuake ships the same control). The eye-separation divisor is
// normalized by (focus/64) so changing focus does NOT change perceived depth strength.
#define Q3E_FOCUS_DEFAULT 160.0f
#define Q3E_DIM_DEFAULT   0.8f

static float def_float(NSString *key, float fallback) {
    NSNumber *v = [NSUserDefaults.standardUserDefaults objectForKey:key];
    return v ? v.floatValue : fallback;
}

static void apply_cvar_f(const char *name, float v) {
    char cmd[96]; snprintf(cmd, sizeof(cmd), "%s %g", name, v); Q3E_QueueCommand(cmd);
}

// Called once at startup (AppShell) to push persisted settings into the
// live layers.
void Q3E_Settings_ApplyAll(void) {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    float legacy = def_float(DEF_TOUCH_SENS, 3.5f);
    Q3E_Input_SetGyro([d boolForKey:DEF_GYRO_ON], def_float(DEF_GYRO_SCALE, 2.0f));
    Q3E_Input_SetTouchSens(def_float(DEF_SENS_X, legacy), def_float(DEF_SENS_Y, legacy));
    Q3E_Input_SetControlStyle(def_float(DEF_CTL_SCALE, 1.0f),
                              def_float(DEF_CTL_ALPHA, 1.0f),
                              [d boolForKey:DEF_LEFTY]);
    Q3E_Shell_SetRefreshMode([d boolForKey:DEF_REFRESH_60]);
    Q3E_Shell_SetFPSCounter([d boolForKey:DEF_FPS_COUNTER]);

    // Engine cvars (aim / display / gameplay).
    apply_cvar_f("m_pitch", [d boolForKey:DEF_INVERT] ? -0.022f : 0.022f);
    apply_cvar_f("cg_fov", def_float(DEF_FOV, 90.0f));
    apply_cvar_f("r_gamma", def_float(DEF_BRIGHTNESS, 1.0f));
    // cl_run 1 = always run; when off, default to walk (touch/pad have no +speed).
    apply_cvar_f("cl_run", [d objectForKey:DEF_ALWAYS_RUN] ? ([d boolForKey:DEF_ALWAYS_RUN] ? 1 : 0) : 1);
    apply_cvar_f("cg_autoswitch", [d objectForKey:DEF_AUTOSWITCH] ? ([d boolForKey:DEF_AUTOSWITCH] ? 1 : 0) : 1);
    apply_cvar_f("cg_simpleItems", [d boolForKey:DEF_SIMPLEITEMS] ? 1 : 0);
    Q3E_Input_SetFireHaptics([d boolForKey:DEF_FIRE_HAPTIC]);
    apply_cvar_f("s_volume", def_float(DEF_SND_VOL, 0.8f));
    apply_cvar_f("s_musicvolume", def_float(DEF_MUS_VOL, 0.8f));
    apply_cvar_f("cg_crosshairSize", def_float(DEF_XHAIR_SIZE, 24.0f));
    apply_cvar_f("cg_drawCrosshair", def_float(DEF_XHAIR_STYLE, 1.0f));
    // r_ext_multisample is latched (needs vid_restart to take effect — the segmented
    // control's action does that); here we just keep the cvar in sync at boot.
    apply_cvar_f("r_ext_multisample", def_float(DEF_MSAA, 0.0f));

#if TARGET_OS_VISION
    // visionOS 3D screen: parallax depth (higher slider = more depth = smaller divisor),
    // convergence plane, panel distance + size, hide-gun, dimming. The divisor feeds
    // BOTH stereo paths: the legacy alternating offset (VK_Set3DSeparation) and the
    // native two-field path (r_stereoSeparation; separation = zProj / divisor), and is
    // normalized by (focus/64) so the crosshair-distance slider doesn't change depth.
    float depth3d = def_float(DEF_DEPTH_3D, Q3E_DEPTH_DEFAULT);
    float focus3d = def_float(DEF_FOCUS_3D, Q3E_FOCUS_DEFAULT);
    float divisor = (20.0f / depth3d) * (focus3d / 64.0f);
    apply_cvar_f("r_zproj", focus3d);
    VK_Set3DSeparation(divisor);
    apply_cvar_f("r_stereoSeparation", divisor);
    Q3E_Set3DPanel(def_float(DEF_DIST_3D, 3.6f), def_float(DEF_SIZE_3D, 2.75f));
    Q3E_Set3DHeight(def_float(DEF_HEIGHT_3D, 0.0f));
    Q3E_Set3DHideGun([d objectForKey:DEF_HIDEGUN_3D] ? [d boolForKey:DEF_HIDEGUN_3D] : 0);
    Q3E_Set3DHideHead([d objectForKey:DEF_HIDEHEAD_3D] ? [d boolForKey:DEF_HIDEHEAD_3D] : 1);
    Q3E_Set3DDim(def_float(DEF_DIM_3D, Q3E_DIM_DEFAULT));
#endif
}

@implementation Q3ESettingsController {
    UISwitch *_gyroSwitch, *_fpsSwitch, *_leftySwitch;
    UISwitch *_invertSwitch, *_alwaysRunSwitch, *_autoSwitchSwitch, *_simpleItemsSwitch, *_fireHapticSwitch;
    UISegmentedControl *_refreshSeg, *_msaaSeg;
    UISlider *_gyroSlider, *_sensXSlider, *_sensYSlider, *_sizeSlider, *_alphaSlider;
    UISlider *_fovSlider, *_brightSlider, *_sndVolSlider, *_musVolSlider, *_xhairSizeSlider, *_xhairStyleSlider;
    UILabel *_gyroValue, *_sensXValue, *_sensYValue, *_sizeValue, *_alphaValue;
    UILabel *_fovValue, *_brightValue, *_sndVolValue, *_musVolValue, *_xhairSizeValue, *_xhairStyleValue;
#if TARGET_OS_VISION
    UISwitch *_hideGunSwitch, *_hideHeadSwitch;
    UISlider *_depthSlider, *_distSlider, *_size3DSlider, *_height3DSlider;
    UISlider *_focusSlider, *_dimSlider;
    UILabel *_depthValue, *_distValue, *_size3DValue, *_height3DValue;
    UILabel *_focusValue, *_dimValue;
    UISegmentedControl *_unitsSeg;
#endif
}

- (UILabel *)section:(NSString *)text {
    UILabel *l = [self label:text size:13 bold:YES];
    l.textColor = [UIColor colorWithRed:1.0 green:0.85 blue:0.2 alpha:0.9];
    return l;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithWhite:0.08 alpha:1.0];
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;

    UILabel *title = [self label:@"Quake3e iOS Settings" size:20 bold:YES];
    UIButton *done = [UIButton buttonWithType:UIButtonTypeSystem];
    [done setTitle:@"Done" forState:UIControlStateNormal];
    done.titleLabel.font = [UIFont boldSystemFontOfSize:17];
    [done addTarget:self action:@selector(dismissSelf) forControlEvents:UIControlEventTouchUpInside];

    float legacy = def_float(DEF_TOUCH_SENS, 3.5f);
    _gyroSwitch = [self makeSwitch:[d boolForKey:DEF_GYRO_ON]];
    _gyroSlider = [self makeSlider:0.5 max:6.0 value:def_float(DEF_GYRO_SCALE, 2.0f)];
    _gyroValue = [self label:@"" size:14 bold:NO];
    _sensXSlider = [self makeSlider:0.5 max:8.0 value:def_float(DEF_SENS_X, legacy)];
    _sensXValue = [self label:@"" size:14 bold:NO];
    _sensYSlider = [self makeSlider:0.5 max:8.0 value:def_float(DEF_SENS_Y, legacy)];
    _sensYValue = [self label:@"" size:14 bold:NO];
    _sizeSlider = [self makeSlider:0.7 max:1.5 value:def_float(DEF_CTL_SCALE, 1.0f)];
    _sizeValue = [self label:@"" size:14 bold:NO];
    _alphaSlider = [self makeSlider:0.4 max:1.6 value:def_float(DEF_CTL_ALPHA, 1.0f)];
    _alphaValue = [self label:@"" size:14 bold:NO];
    _leftySwitch = [self makeSwitch:[d boolForKey:DEF_LEFTY]];
#if TARGET_OS_VISION
    NSInteger maxHz = 90; // UIScreen unavailable on visionOS; compositor cadence
#else
    NSInteger maxHz = UIScreen.mainScreen.maximumFramesPerSecond;
#endif
    NSString *nativeLabel = [NSString stringWithFormat:@"Native (%ld Hz)", (long)maxHz];
    _refreshSeg = [[UISegmentedControl alloc] initWithItems:@[@"60 Hz", nativeLabel]];
    _refreshSeg.selectedSegmentIndex = [d boolForKey:DEF_REFRESH_60] ? 0 : 1;
    [_refreshSeg addTarget:self action:@selector(changed) forControlEvents:UIControlEventValueChanged];
    _fpsSwitch = [self makeSwitch:[d boolForKey:DEF_FPS_COUNTER]];

    _invertSwitch = [self makeSwitch:[d boolForKey:DEF_INVERT]];
    _fovSlider = [self makeSlider:60 max:130 value:def_float(DEF_FOV, 90.0f)];
    _fovValue = [self label:@"" size:14 bold:NO];
    _brightSlider = [self makeSlider:0.5 max:3.0 value:def_float(DEF_BRIGHTNESS, 1.0f)];
    _brightValue = [self label:@"" size:14 bold:NO];
    _alwaysRunSwitch = [self makeSwitch:([d objectForKey:DEF_ALWAYS_RUN] ? [d boolForKey:DEF_ALWAYS_RUN] : YES)];
    _autoSwitchSwitch = [self makeSwitch:([d objectForKey:DEF_AUTOSWITCH] ? [d boolForKey:DEF_AUTOSWITCH] : YES)];
    _simpleItemsSwitch = [self makeSwitch:[d boolForKey:DEF_SIMPLEITEMS]];
    _fireHapticSwitch = [self makeSwitch:[d boolForKey:DEF_FIRE_HAPTIC]];
    _sndVolSlider = [self makeSlider:0.0 max:1.0 value:def_float(DEF_SND_VOL, 0.8f)];
    _sndVolValue = [self label:@"" size:14 bold:NO];
    _musVolSlider = [self makeSlider:0.0 max:1.0 value:def_float(DEF_MUS_VOL, 0.8f)];
    _musVolValue = [self label:@"" size:14 bold:NO];
    _xhairSizeSlider = [self makeSlider:8 max:48 value:def_float(DEF_XHAIR_SIZE, 24.0f)];
    _xhairSizeValue = [self label:@"" size:14 bold:NO];
    _xhairStyleSlider = [self makeSlider:1 max:10 value:def_float(DEF_XHAIR_STYLE, 1.0f)];
    _xhairStyleValue = [self label:@"" size:14 bold:NO];
    _msaaSeg = [[UISegmentedControl alloc] initWithItems:@[@"Off", @"2×", @"4×", @"8×"]];
    {
        int msaa = (int)def_float(DEF_MSAA, 0.0f);
        _msaaSeg.selectedSegmentIndex = (msaa >= 8) ? 3 : (msaa >= 4) ? 2 : (msaa >= 2) ? 1 : 0;
    }
    [_msaaSeg addTarget:self action:@selector(msaaChanged) forControlEvents:UIControlEventValueChanged];
#if TARGET_OS_VISION
    _hideGunSwitch = [self makeSwitch:([d objectForKey:DEF_HIDEGUN_3D] ? [d boolForKey:DEF_HIDEGUN_3D] : NO)];
    _hideHeadSwitch = [self makeSwitch:([d objectForKey:DEF_HIDEHEAD_3D] ? [d boolForKey:DEF_HIDEHEAD_3D] : YES)];
    _depthSlider = [self makeSlider:0.1 max:1.0 value:MIN(def_float(DEF_DEPTH_3D, Q3E_DEPTH_DEFAULT), 1.0f)];
    _depthValue = [self label:@"" size:14 bold:NO];
    _focusSlider = [self makeSlider:64 max:400 value:def_float(DEF_FOCUS_3D, Q3E_FOCUS_DEFAULT)];
    _focusValue = [self label:@"" size:14 bold:NO];
    _dimSlider = [self makeSlider:0.0 max:1.0 value:def_float(DEF_DIM_3D, Q3E_DIM_DEFAULT)];
    _dimValue = [self label:@"" size:14 bold:NO];
    _unitsSeg = [[UISegmentedControl alloc] initWithItems:@[@"m", @"ft"]];
    _unitsSeg.selectedSegmentIndex = [d boolForKey:DEF_UNITS_FT] ? 1 : 0;
    [_unitsSeg addTarget:self action:@selector(changed) forControlEvents:UIControlEventValueChanged];
    _distSlider = [self makeSlider:1.5 max:6.0 value:def_float(DEF_DIST_3D, 3.6f)];
    _distValue = [self label:@"" size:14 bold:NO];
    _size3DSlider = [self makeSlider:1.0 max:4.0 value:def_float(DEF_SIZE_3D, 2.75f)];
    _size3DValue = [self label:@"" size:14 bold:NO];
    _height3DSlider = [self makeSlider:-1.5 max:10.0 value:def_float(DEF_HEIGHT_3D, 0.0f)];
    _height3DValue = [self label:@"" size:14 bold:NO];
#endif

    UIStackView *rows = [[UIStackView alloc] init];
    rows.axis = UILayoutConstraintAxisVertical;
    rows.spacing = 14;
    rows.translatesAutoresizingMaskIntoConstraints = NO;

    UIStackView *header = [self row:@[title, done]];
    [rows addArrangedSubview:header];

#if TARGET_OS_VISION
    UIButton *reset3D = [UIButton buttonWithType:UIButtonTypeSystem];
    [reset3D setTitle:@"Reset" forState:UIControlStateNormal];
    reset3D.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    [reset3D addTarget:self action:@selector(reset3DDefaults) forControlEvents:UIControlEventTouchUpInside];
    [rows addArrangedSubview:[self row:@[[self section:@"3D SCREEN (VISION PRO)"], reset3D]]];
    [rows addArrangedSubview:[self row:@[[self label:@"Hide gun in 3D" size:16 bold:NO], _hideGunSwitch]]];
    [rows addArrangedSubview:[self row:@[[self label:@"2D HUD" size:16 bold:NO], _hideHeadSwitch]]];
    [rows addArrangedSubview:[self row:@[[self label:@"Stereo depth" size:16 bold:NO], _depthSlider, _depthValue]]];
    [rows addArrangedSubview:[self row:@[[self label:@"Crosshair distance" size:16 bold:NO], _focusSlider, _focusValue]]];
    [rows addArrangedSubview:[self row:@[[self label:@"Dim surroundings" size:16 bold:NO], _dimSlider, _dimValue]]];
    [rows addArrangedSubview:[self row:@[[self label:@"Screen distance" size:16 bold:NO], _distSlider, _distValue]]];
    [rows addArrangedSubview:[self row:@[[self label:@"Screen size" size:16 bold:NO], _size3DSlider, _size3DValue]]];
    [rows addArrangedSubview:[self row:@[[self label:@"Screen position height" size:16 bold:NO], _height3DSlider, _height3DValue]]];
    [rows addArrangedSubview:[self row:@[[self label:@"Units" size:16 bold:NO], _unitsSeg]]];
#endif

    [rows addArrangedSubview:[self section:@"AIM"]];
    [rows addArrangedSubview:[self row:@[[self label:@"Look sensitivity X" size:16 bold:NO], _sensXSlider, _sensXValue]]];
    [rows addArrangedSubview:[self row:@[[self label:@"Look sensitivity Y" size:16 bold:NO], _sensYSlider, _sensYValue]]];
    [rows addArrangedSubview:[self row:@[[self label:@"Invert look" size:16 bold:NO], _invertSwitch]]];
    [rows addArrangedSubview:[self row:@[[self label:@"Gyro aim" size:16 bold:NO], _gyroSwitch]]];
    [rows addArrangedSubview:[self row:@[[self label:@"Gyro intensity" size:14 bold:NO], _gyroSlider, _gyroValue]]];

    [rows addArrangedSubview:[self section:@"DISPLAY"]];
    [rows addArrangedSubview:[self row:@[[self label:@"Field of view" size:16 bold:NO], _fovSlider, _fovValue]]];
    [rows addArrangedSubview:[self row:@[[self label:@"Brightness" size:16 bold:NO], _brightSlider, _brightValue]]];
    [rows addArrangedSubview:[self row:@[[self label:@"Refresh rate" size:16 bold:NO], _refreshSeg]]];
    [rows addArrangedSubview:[self row:@[[self label:@"Anti-aliasing" size:16 bold:NO], _msaaSeg]]];
    [rows addArrangedSubview:[self row:@[[self label:@"Crosshair size" size:16 bold:NO], _xhairSizeSlider, _xhairSizeValue]]];
    [rows addArrangedSubview:[self row:@[[self label:@"Crosshair style" size:16 bold:NO], _xhairStyleSlider, _xhairStyleValue]]];

    [rows addArrangedSubview:[self section:@"AUDIO"]];
    [rows addArrangedSubview:[self row:@[[self label:@"Sound volume" size:16 bold:NO], _sndVolSlider, _sndVolValue]]];
    [rows addArrangedSubview:[self row:@[[self label:@"Music volume" size:16 bold:NO], _musVolSlider, _musVolValue]]];

    [rows addArrangedSubview:[self section:@"TOUCH CONTROLS"]];
    [rows addArrangedSubview:[self row:@[[self label:@"Controls size" size:16 bold:NO], _sizeSlider, _sizeValue]]];
    [rows addArrangedSubview:[self row:@[[self label:@"Controls opacity" size:16 bold:NO], _alphaSlider, _alphaValue]]];
    [rows addArrangedSubview:[self row:@[[self label:@"Fire haptics" size:16 bold:NO], _fireHapticSwitch]]];
    [rows addArrangedSubview:[self row:@[[self label:@"Left-handed layout" size:16 bold:NO], _leftySwitch]]];

    [rows addArrangedSubview:[self section:@"GAMEPLAY"]];
    [rows addArrangedSubview:[self row:@[[self label:@"Always run" size:16 bold:NO], _alwaysRunSwitch]]];
    [rows addArrangedSubview:[self row:@[[self label:@"Auto-switch weapons" size:16 bold:NO], _autoSwitchSwitch]]];
    [rows addArrangedSubview:[self row:@[[self label:@"Simple items" size:16 bold:NO], _simpleItemsSwitch]]];
    [rows addArrangedSubview:[self row:@[[self label:@"FPS counter" size:16 bold:NO], _fpsSwitch]]];


    UIScrollView *scroll = [[UIScrollView alloc] init];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:scroll];
    [scroll addSubview:rows];
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor],
        [rows.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:18],
        [rows.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-18],
        [rows.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:24],
        [rows.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-24],
        [rows.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-48],
    ]];
    [self refreshValueLabels];
}

- (UILabel *)label:(NSString *)text size:(CGFloat)size bold:(BOOL)bold {
    UILabel *l = [[UILabel alloc] init];
    l.text = text;
    l.textColor = UIColor.whiteColor;
    l.font = bold ? [UIFont boldSystemFontOfSize:size] : [UIFont systemFontOfSize:size];
    return l;
}

- (UISwitch *)makeSwitch:(BOOL)on {
    UISwitch *s = [[UISwitch alloc] init];
    s.on = on;
    [s addTarget:self action:@selector(changed) forControlEvents:UIControlEventValueChanged];
    return s;
}

- (UISlider *)makeSlider:(float)min max:(float)max value:(float)v {
    UISlider *s = [[UISlider alloc] init];
    s.minimumValue = min;
    s.maximumValue = max;
    s.value = v;
    [s addTarget:self action:@selector(changed) forControlEvents:UIControlEventValueChanged];
    [s.widthAnchor constraintGreaterThanOrEqualToConstant:220].active = YES;
    return s;
}

- (UIStackView *)row:(NSArray<UIView *> *)views {
    UIStackView *r = [[UIStackView alloc] initWithArrangedSubviews:views];
    r.axis = UILayoutConstraintAxisHorizontal;
    r.spacing = 16;
    r.distribution = UIStackViewDistributionEqualSpacing;
    r.alignment = UIStackViewAlignmentCenter;
    return r;
}

- (void)refreshValueLabels {
    _gyroValue.text = [NSString stringWithFormat:@"%.1f", _gyroSlider.value];
    _sensXValue.text = [NSString stringWithFormat:@"%.1f", _sensXSlider.value];
    _sensYValue.text = [NSString stringWithFormat:@"%.1f", _sensYSlider.value];
    _sizeValue.text = [NSString stringWithFormat:@"%.0f%%", _sizeSlider.value * 100];
    _alphaValue.text = [NSString stringWithFormat:@"%.0f%%", _alphaSlider.value * 100];
    _fovValue.text = [NSString stringWithFormat:@"%.0f", _fovSlider.value];
    _brightValue.text = [NSString stringWithFormat:@"%.1f", _brightSlider.value];
    _sndVolValue.text = [NSString stringWithFormat:@"%.0f%%", _sndVolSlider.value * 100];
    _musVolValue.text = [NSString stringWithFormat:@"%.0f%%", _musVolSlider.value * 100];
    _xhairSizeValue.text = [NSString stringWithFormat:@"%.0f", _xhairSizeSlider.value];
    _xhairStyleValue.text = [NSString stringWithFormat:@"%.0f", roundf(_xhairStyleSlider.value)];
#if TARGET_OS_VISION
    _depthValue.text = [NSString stringWithFormat:@"%.0f%%", _depthSlider.value * 100];
    _focusValue.text = (_focusSlider.value < 96)  ? @"near"
                     : (_focusSlider.value < 240) ? @"mid" : @"far";
    _dimValue.text = [NSString stringWithFormat:@"%.0f%%", _dimSlider.value * 100];
    // Panel measurements honor the m/ft toggle (screen size is the FULL width, 2x halfW).
    BOOL ft = (_unitsSeg.selectedSegmentIndex == 1);
    float k = ft ? 3.28084f : 1.0f;
    NSString *u = ft ? @"ft" : @"m";
    _distValue.text = [NSString stringWithFormat:@"%.1f %@", _distSlider.value * k, u];
    _size3DValue.text = [NSString stringWithFormat:@"%.1f %@ wide", _size3DSlider.value * 2.0f * k, u];
    _height3DValue.text = [NSString stringWithFormat:@"%+.1f %@", _height3DSlider.value * k, u];
#endif
}

- (void)changed {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    [d setBool:_gyroSwitch.on forKey:DEF_GYRO_ON];
    [d setFloat:_gyroSlider.value forKey:DEF_GYRO_SCALE];
    [d setFloat:_sensXSlider.value forKey:DEF_SENS_X];
    [d setFloat:_sensYSlider.value forKey:DEF_SENS_Y];
    [d setFloat:_sizeSlider.value forKey:DEF_CTL_SCALE];
    [d setFloat:_alphaSlider.value forKey:DEF_CTL_ALPHA];
    [d setBool:_leftySwitch.on forKey:DEF_LEFTY];
    [d setBool:(_refreshSeg.selectedSegmentIndex == 0) forKey:DEF_REFRESH_60];
    [d setBool:_fpsSwitch.on forKey:DEF_FPS_COUNTER];
    [d setBool:_invertSwitch.on forKey:DEF_INVERT];
    [d setFloat:_fovSlider.value forKey:DEF_FOV];
    [d setFloat:_brightSlider.value forKey:DEF_BRIGHTNESS];
    [d setBool:_alwaysRunSwitch.on forKey:DEF_ALWAYS_RUN];
    [d setBool:_autoSwitchSwitch.on forKey:DEF_AUTOSWITCH];
    [d setBool:_simpleItemsSwitch.on forKey:DEF_SIMPLEITEMS];
    [d setBool:_fireHapticSwitch.on forKey:DEF_FIRE_HAPTIC];
    [d setFloat:_sndVolSlider.value forKey:DEF_SND_VOL];
    [d setFloat:_musVolSlider.value forKey:DEF_MUS_VOL];
    [d setFloat:_xhairSizeSlider.value forKey:DEF_XHAIR_SIZE];
    [d setFloat:roundf(_xhairStyleSlider.value) forKey:DEF_XHAIR_STYLE];
    { const int msaaVals[] = {0, 2, 4, 8};
      [d setFloat:msaaVals[_msaaSeg.selectedSegmentIndex] forKey:DEF_MSAA]; }
#if TARGET_OS_VISION
    [d setBool:_hideGunSwitch.on forKey:DEF_HIDEGUN_3D];
    [d setBool:_hideHeadSwitch.on forKey:DEF_HIDEHEAD_3D];
    [d setBool:(_unitsSeg.selectedSegmentIndex == 1) forKey:DEF_UNITS_FT];
    [d setFloat:_depthSlider.value forKey:DEF_DEPTH_3D];
    [d setFloat:_focusSlider.value forKey:DEF_FOCUS_3D];
    [d setFloat:_dimSlider.value forKey:DEF_DIM_3D];
    [d setFloat:_distSlider.value forKey:DEF_DIST_3D];
    [d setFloat:_size3DSlider.value forKey:DEF_SIZE_3D];
    [d setFloat:_height3DSlider.value forKey:DEF_HEIGHT_3D];
#endif
    [self refreshValueLabels];
    Q3E_Settings_ApplyAll();
}

#if TARGET_OS_VISION
// Restore the tuned 3D defaults (the values dialed in during bring-up).
- (void)reset3DDefaults {
    _hideGunSwitch.on = NO;       // gun visible by default (Austin, post-D-022)
    _hideHeadSwitch.on = YES;
    _depthSlider.value = Q3E_DEPTH_DEFAULT;   // 60% — comfort pick after both-eyes fix
    _focusSlider.value = Q3E_FOCUS_DEFAULT;   // convergence out where combat happens
    _dimSlider.value = Q3E_DIM_DEFAULT;       // 80% — perceptual-curve default
    _distSlider.value = 3.6f;     // metres
    _size3DSlider.value = 2.75f;  // half-width metres
    _height3DSlider.value = 0.0f; // eye level, no tilt
    [self changed];
}
#endif

// Anti-aliasing (r_ext_multisample) is latched — save + apply the cvar, then vid_restart
// to make it take effect. (Kept out of the generic slider path so other tweaks don't
// trigger a renderer restart.)
- (void)msaaChanged {
    [self changed];
    Q3E_QueueCommand("vid_restart");
}

- (void)dismissSelf {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)showPaks {
    void Q3E_PresentPakList(UIViewController *from);
    Q3E_PresentPakList(self);
}

@end

// Open settings without a source view — finds the active window's root VC. Used by the
// visionOS ornament so settings is reachable while immersive (live 3D-panel tuning).
void Q3E_OpenSettings(void) {
    // Find any window-scene window with a root VC (prefer the key window). The strict
    // isKeyWindow + foregroundActive filter failed on the SwiftUI window, so be lenient.
    UIViewController *root = nil;
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if (![s isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *win in ((UIWindowScene *)s).windows) {
            if (!win.rootViewController) continue;
            if (!root) root = win.rootViewController;      // fallback: first with a root
            if (win.isKeyWindow) { root = win.rootViewController; break; }
        }
        if (root && root.view.window.isKeyWindow) break;
    }
    if (!root) return;
    while (root.presentedViewController) root = root.presentedViewController;   // topmost
    if ([root isKindOfClass:Q3ESettingsController.class]) return;               // already up
    Q3ESettingsController *vc = [Q3ESettingsController new];
    vc.modalPresentationStyle = UIModalPresentationFormSheet;
    [root presentViewController:vc animated:YES completion:nil];
}

void Q3E_PresentSettings(UIView *fromView) {
    UIViewController *root = fromView.window.rootViewController;
    if (!root || root.presentedViewController) return;
    Q3ESettingsController *vc = [Q3ESettingsController new];
    vc.modalPresentationStyle = UIModalPresentationFormSheet;
    [root presentViewController:vc animated:YES completion:nil];
}
