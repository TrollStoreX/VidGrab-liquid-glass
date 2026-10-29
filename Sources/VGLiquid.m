#import "VGLiquid.h"
#import <objc/runtime.h>

// Liquid Glass for VidGrab.
//
// Two glasses, one look:
//  * iOS 26 has "UIGlassEffect": real Liquid Glass, it bends what is behind it and lights its own edge.
//    The class, the effect and its properties are all looked up at runtime, so the app still builds and
//    runs on iOS 15 exactly as before.
//  * Everywhere else the same glass is drawn: a blur of what is behind, a see-through tint from the
//    palette, a bright edge that fades out at the bottom right (the lit rim), a soft inner light and a
//    drop shadow so the piece floats. This is the look the user sees on iOS 15 to 18.

NSString *const VGGlassDidChangeNotification = @"VGGlassDidChangeNotification";

static NSString *const kVGGlassOnKey = @"vgLiquidGlass";
static char kVGStoredBackground;   // the view's own background color, kept while glass is on
static char kVGGlassBackdropTag;   // the extra drawn-glass view, nil when the real thing is used
static char kVGGlassRadiusKey;
static char kVGGlassDarkKey;

static BOOL gReduce = NO;          // Reduce Transparency, as last heard from the system

static NSString *const kGlassBackground = @"vgGlassBackground";   // the drawn glass layer
static NSString *const kGlassRim = @"vgGlassRim";                 // the lit edge
static NSString *const kGlassHighlight = @"vgGlassHighlight";     // the bright spot's mask
static NSString *const kGlassGlow = @"vgGlassGlow";               // soft inner white line

#pragma mark - System pieces

static Class GlassEffectClass(void) {
    static Class c;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (@available(iOS 26.0, *)) c = NSClassFromString(@"UIGlassEffect");
    });
    return c;
}

static BOOL HasRealGlass(void) {
    return GlassEffectClass() != Nil;
}

/// `+[UIGlassEffect effectWithStyle:]` on iOS 26, nil before that.
static id MakeGlassEffect(BOOL dark) {
    Class c = GlassEffectClass();
    if (!c) return nil;
    SEL sel = NSSelectorFromString(@"effectWithStyle:");
    if (![c respondsToSelector:sel]) return nil;
    typedef id (*Fn)(id, SEL, NSInteger);
    IMP mk = [c methodForSelector:sel];
    id effect = ((Fn)mk)((id)c, sel, dark ? 1 : 0);   // 0 = regular, 1 = clear (over video)
    [effect setValue:@NO forKey:@"interactive"];   // no wobble when a finger is near: VidGrab's glass is decoration
    return effect;
}

static BOOL IsGlassSuperview(UIView *v) {
    Class c = GlassEffectClass();
    return c && [v isKindOfClass:c];
}

/// iOS 26's own glass styling for the bars' buttons and labels ("glass" configuration, done).
void VGStyleBarItem(UIBarButtonItem *item) {
    if (!item || !HasRealGlass()) return;
    @try {
        id c = [item valueForKey:@"_configuration"];
        if (!c) return;
        SEL setStyle = NSSelectorFromString(@"setStyle:");
        if ([c respondsToSelector:setStyle]) {
            typedef void (*VoidInt)(id, SEL, NSInteger);
            IMP imp = [c methodForSelector:setStyle];
            ((VoidInt)imp)(c, setStyle, 3);   // 3 = glass
            SEL bgSel = NSSelectorFromString(@"setBackgroundStyle:");
            if ([c respondsToSelector:bgSel]) ((VoidInt)[c methodForSelector:bgSel])(c, bgSel, 1);
        }
        SEL done = NSSelectorFromString(@"_setConfiguration:");
        if ([item respondsToSelector:done]) {
            typedef void (*VoidId)(id, SEL, id);
            ((VoidId)[item methodForSelector:done])(item, done, c);
        }
    } @catch (__unused NSException *e) { }
}

void VGStyleNavigationBar(UINavigationBar *bar) {
    if (!bar || !HasRealGlass() || ![bar isKindOfClass:UINavigationBar.class]) return;
    [bar layoutIfNeeded];
    NSMutableArray<UINavigationItem *> *items = [NSMutableArray array];
    if (bar.topItem) [items addObject:bar.topItem];
    if (bar.backItem) [items addObject:bar.backItem];
    for (UINavigationItem *item in items) {
        for (UIBarButtonItem *one in item.leftBarButtonItems ?: @[]) VGStyleBarItem(one);
        for (UIBarButtonItem *one in item.rightBarButtonItems ?: @[]) VGStyleBarItem(one);
    }
}

#pragma mark - Drawn glass

static UIColor *GlassTint(void) {
    VGPalette *p = VGPalette.current;
    if (p.light) return [p.surface colorWithAlphaComponent:0.42];
    return [p.surface colorWithAlphaComponent:0.38];
}

static UIColor *GlassEdge(void) {
    VGPalette *p = VGPalette.current;
    if (p.light) return [UIColor colorWithWhite:0 alpha:0.10];
    return [UIColor colorWithWhite:1 alpha:0.14];
}

static CALayer *HighlightMask(void);

static CAGradientLayer *RimLayer(void) {
    CAGradientLayer *rim = [CAGradientLayer layer];
    BOOL light = VGLight;
    rim.colors = @[(id)[UIColor colorWithWhite:1 alpha:light ? 0.95 : 0.62].CGColor,
                   (id)[UIColor colorWithWhite:light ? 0.55 : 1 alpha:light ? 0.45 : 0.20].CGColor,
                   (id)[UIColor colorWithWhite:light ? 0.35 : 1 alpha:0.06].CGColor];
    rim.locations = @[@0.0, @0.55, @1.0];
    rim.startPoint = CGPointMake(0.12, 0.0);
    rim.endPoint = CGPointMake(0.88, 1.0);
    rim.mask = HighlightMask();
    return rim;
}

/// The bright spot in the top-left that fades across the piece, like light falling on the glass.
static CALayer *HighlightMask(void) {
    CAGradientLayer *g = [CAGradientLayer layer];
    g.type = kCAGradientLayerRadial;
    g.colors = @[(id)[UIColor whiteColor].CGColor, (id)[UIColor whiteColor].CGColor, (id)[UIColor clearColor].CGColor];
    g.locations = @[@0.0, @0.55, @1.0];
    g.startPoint = CGPointMake(0.05, 0.0);
    g.endPoint = CGPointMake(0.95, 1.0);
    return g;
}

typedef NS_ENUM(NSInteger, VGGlassCornerStyle) { VGGlassCornersAll, VGGlassCornersTop, VGGlassCornersBottom };

static UIBezierPath *GlassPath(CGRect b, CGFloat r, VGGlassCornerStyle style) {
    CGFloat x0 = 0, y0 = 0, x1 = b.size.width, y1 = b.size.height;
    CGFloat top = (style == VGGlassCornersAll || style == VGGlassCornersTop) ? r : 0;
    CGFloat bottom = (style == VGGlassCornersAll || style == VGGlassCornersBottom) ? r : 0;
    UIBezierPath *p = [UIBezierPath bezierPath];
    [p moveToPoint:CGPointMake(x0, y0 + top)];
    if (top > 0) [p addArcWithCenter:CGPointMake(x0 + top, y0 + top) radius:top startAngle:M_PI endAngle:M_PI * 1.5 clockwise:YES];
    else [p addLineToPoint:CGPointMake(x0, y0)];
    [p addLineToPoint:CGPointMake(x1 - top, y0)];
    if (top > 0) [p addArcWithCenter:CGPointMake(x1 - top, y0 + top) radius:top startAngle:M_PI * 1.5 endAngle:0 clockwise:YES];
    [p addLineToPoint:CGPointMake(x1, y1 - bottom)];
    if (bottom > 0) [p addArcWithCenter:CGPointMake(x1 - bottom, y1 - bottom) radius:bottom startAngle:0 endAngle:M_PI_2 clockwise:YES];
    else [p addLineToPoint:CGPointMake(x1, y1)];
    [p addLineToPoint:CGPointMake(x0 + bottom, y1)];
    if (bottom > 0) [p addArcWithCenter:CGPointMake(x0 + bottom, y1 - bottom) radius:bottom startAngle:M_PI_2 endAngle:M_PI clockwise:YES];
    [p closePath];
    return p;
}

static void LayoutDrawnGlass(UIView *host, UIVisualEffectView *glass, BOOL dark, BOOL dense) {
    CGRect b = glass.bounds;
    if (b.size.width < 1 || b.size.height < 1) return;
    CGFloat radius = [objc_getAssociatedObject(host, &kVGGlassRadiusKey) doubleValue];
    VGGlassCornerStyle style = VGGlassCornersAll;
    UIBezierPath *path;
    if (radius > 0.5) {
        path = GlassPath(b, radius, style);
    } else {
        // Radius 0: a full-width bar. Round the edge it hangs from, like the bars on iOS 26.
        UIView *parent = host.superview;
        UIEdgeInsets in = parent ? parent.safeAreaInsets : UIEdgeInsetsZero;
        CGFloat parentW = parent ? parent.bounds.size.width : 0, parentH = parent ? parent.bounds.size.height : 0;
        BOOL atTop = host.frame.origin.y <= MAX(in.top, 1);
        BOOL atBottom = CGRectGetMaxY(host.frame) >= parentH - MAX(in.bottom, 1) - 0.5;
        if (atTop || atBottom) {
            path = GlassPath(b, 26, atTop ? VGGlassCornersBottom : VGGlassCornersTop);
        } else if (parentW > 0 && host.bounds.size.width >= parentW - 1) {
            path = GlassPath(b, 26, VGGlassCornersAll);   // a bar that is not at either edge: round both ends
        } else {
            return;   // an ordinary flat view: let it be
        }
    }
    CAShapeLayer *mask = [CAShapeLayer layer];
    mask.path = path.CGPath;
    glass.layer.mask = mask;

    // Tint from the theme, so VidGrab's glass still looks like VidGrab.
    UIView *tint = [glass.contentView viewWithTag:0x6C1];
    if (!tint) {
        tint = [UIView new];
        tint.tag = 0x6C1;
        tint.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        tint.userInteractionEnabled = NO;
        [glass.contentView insertSubview:tint atIndex:0];
    }
    tint.frame = b;
    tint.backgroundColor = dark ? [UIColor colorWithWhite:0 alpha:0.16]
                                : [GlassTint() colorWithAlphaComponent:(dense ? 0.55 : 0.38)];

    // The lit edge: a 1pt line, brighter top-left, almost gone bottom-right.
    static char kRimKey, kGlowKey;
    CAShapeLayer *rim = objc_getAssociatedObject(glass, &kRimKey);
    if (!rim) {
        rim = (CAShapeLayer *)RimLayer();
        rim.fillColor = UIColor.clearColor.CGColor;
        rim.lineWidth = 1;
        rim.zPosition = 10;
        [glass.layer addSublayer:rim];
        objc_setAssociatedObject(glass, &kRimKey, rim, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    rim.frame = b;
    rim.path = path.CGPath;

    // A soft light just inside the edge (sits on the blur, not on our own tint).
    CAShapeLayer *glow = objc_getAssociatedObject(glass, &kGlowKey);
    if (!glow) {
        glow = (CAShapeLayer *)RimLayer();
        CAShapeLayer *m = [CAShapeLayer layer];
        m.fillColor = UIColor.clearColor.CGColor;
        m.strokeColor = UIColor.blackColor.CGColor;
        m.lineWidth = 6;
        m.shadowColor = UIColor.blackColor.CGColor;
        m.shadowOpacity = 0.6;
        m.shadowRadius = 3;
        m.shadowOffset = CGSizeZero;
        m.opacity = 0.55;
        glow.mask = m;
        glow.opacity = 0.55;
        [glass.contentView.layer addSublayer:glow];
        objc_setAssociatedObject(glass, &kGlowKey, glow, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    glow.frame = b;
    glow.path = path.CGPath;
    CAShapeLayer *gm = (CAShapeLayer *)[glow mask];
    gm.frame = b;
    gm.path = path.CGPath;

    // Depth: the piece floats over the page.
    glass.layer.shadowPath = path.CGPath;
    glass.layer.shadowColor = UIColor.blackColor.CGColor;
    glass.layer.shadowOpacity = dark ? 0.45 : 0.28;
    glass.layer.shadowRadius = 18;
    glass.layer.shadowOffset = CGSizeMake(0, 8);
}

#pragma mark - Glass hosts

/// UIVisualEffectView that draws its glass again whenever it changes size.
@interface VGDrawnGlassView : UIVisualEffectView
@property (nonatomic, weak) UIView *host;
@property (nonatomic, assign) BOOL dark;
@property (nonatomic, assign) BOOL dense;
@end

@implementation VGDrawnGlassView
- (void)layoutSubviews {
    [super layoutSubviews];
    LayoutDrawnGlass(self.host ?: self, self, self.dark, self.dense);
}
- (void)setDense:(BOOL)dense { _dense = dense; [self setNeedsLayout]; }
- (void)setDark:(BOOL)dark { _dark = dark; [self setNeedsLayout]; }
@end

@interface VGGlassView ()
@property (nonatomic, assign) BOOL dark;   // kept for the build override below
@end

@implementation VGGlassView

@synthesize dark = _glassViewDark;

- (void)build {
    self.userInteractionEnabled = NO;
    if (HasRealGlass()) {
        self.effect = (UIVisualEffect *)MakeGlassEffect(self.dark);
        self.layer.cornerRadius = VGGlassRadius;
        self.layer.cornerCurve = kCACornerCurveContinuous;
        self.clipsToBounds = YES;
        return;
    }
    self.effect = [UIBlurEffect effectWithStyle:self.dark || !VGLight ? UIBlurEffectStyleSystemMaterialDark : UIBlurEffectStyleSystemMaterialLight];
    self.backgroundColor = UIColor.clearColor;
}

@synthesize dense = _dense, roundTop = _roundTop, roundBottom = _roundBottom;
- (BOOL)dark { return _glassViewDark; }
- (void)setDark:(BOOL)dark { _glassViewDark = dark; [self build]; [self setNeedsLayout]; }
- (void)setDense:(BOOL)dense { _dense = dense; [self setNeedsLayout]; }

- (void)layoutSubviews {
    [super layoutSubviews];
    if (HasRealGlass()) {
        // The real glass rounds itself; only mask it when it is a full-width bar.
        if (self.roundTop || self.roundBottom) {
            VGGlassCornerStyle s = self.roundTop ? VGGlassCornersBottom : VGGlassCornersTop;
            UIBezierPath *path = GlassPath(self.bounds, 26, s);
            CAShapeLayer *m = (CAShapeLayer *)self.layer.mask;
            if (![m isKindOfClass:CAShapeLayer.class]) { m = [CAShapeLayer layer]; self.layer.mask = m; }
            m.path = path.CGPath;
        } else {
            self.layer.mask = nil;
        }
        return;
    }
}
@end

#pragma mark - Public

BOOL VGLiquidEnabled(void) {
    NSNumber *n = [NSUserDefaults.standardUserDefaults objectForKey:kVGGlassOnKey];
    BOOL on = n ? n.boolValue : YES;
    return on && !gReduce;
}

void VGLiquidSetEnabled(BOOL on) {
    [NSUserDefaults.standardUserDefaults setBool:on forKey:kVGGlassOnKey];
    [NSNotificationCenter.defaultCenter postNotificationName:VGGlassDidChangeNotification object:nil];
    [NSNotificationCenter.defaultCenter postNotificationName:VGThemeDidChangeNotification object:nil];
}

static BOOL gListening = NO;

void VGLiquidListenForAccessibility(void) {
    if (gListening) return;
    gListening = YES;
    gReduce = UIAccessibilityIsReduceTransparencyEnabled();
    [NSNotificationCenter.defaultCenter addObserverForName:UIAccessibilityReduceTransparencyStatusDidChangeNotification
                                                    object:nil queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification *n) {
        gReduce = UIAccessibilityIsReduceTransparencyEnabled();
        [NSNotificationCenter.defaultCenter postNotificationName:VGGlassDidChangeNotification object:nil];
        [NSNotificationCenter.defaultCenter postNotificationName:VGThemeDidChangeNotification object:nil];
    }];
}

BOOL VGHasGlass(UIView *view) {
    return objc_getAssociatedObject(view, &kVGStoredBackground) != nil;
}

void VGRemoveGlass(UIView *view) {
    UIView *glass = objc_getAssociatedObject(view, &kVGGlassBackdropTag);
    if ([glass isKindOfClass:UIView.class]) [glass removeFromSuperview];
    objc_setAssociatedObject(view, &kVGGlassBackdropTag, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UIColor *old = objc_getAssociatedObject(view, &kVGStoredBackground);
    if (old) view.backgroundColor = [old isKindOfClass:UIColor.class] ? old : UIColor.clearColor;
    objc_setAssociatedObject(view, &kVGStoredBackground, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    view.layer.borderWidth = 0;
    view.layer.shadowOpacity = 0;
}

void VGApplyGlass(UIView *view, CGFloat radius, BOOL dark) {
    if (!view) return;
    if (!VGLiquidEnabled()) { VGRemoveGlass(view); return; }
    BOOL already = VGHasGlass(view);
    UIView *glass = objc_getAssociatedObject(view, &kVGGlassBackdropTag);

    BOOL real = HasRealGlass();
    BOOL wrongKind = glass && real != [glass isKindOfClass:UIVisualEffectView.class];
    if (glass && (wrongKind || (!real && ![glass isKindOfClass:VGDrawnGlassView.class]))) {
        [glass removeFromSuperview];
        glass = nil;
    }
    if (!already) {
        objc_setAssociatedObject(view, &kVGStoredBackground, view.backgroundColor ?: (id)NSNull.null, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        view.backgroundColor = UIColor.clearColor;
        view.layer.borderWidth = 0;
        view.layer.shadowOpacity = 0;
    }
    objc_setAssociatedObject(view, &kVGGlassRadiusKey, @(radius), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(view, &kVGGlassDarkKey, @(dark), OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    if (!glass) {
        if (real) {
            VGGlassView *g = [[VGGlassView alloc] initWithEffect:(UIVisualEffect *)MakeGlassEffect(dark)];
            g.dark = dark;
            g.userInteractionEnabled = NO;
            g.layer.cornerRadius = radius > 0 ? radius : 0;
            g.layer.cornerCurve = kCACornerCurveContinuous;
            g.clipsToBounds = radius > 0;
            glass = g;
        } else {
            VGDrawnGlassView *g = [VGDrawnGlassView new];
            g.host = view;
            g.dark = dark;
            g.effect = [UIBlurEffect effectWithStyle:(dark || !VGLight) ? UIBlurEffectStyleSystemMaterialDark : UIBlurEffectStyleSystemMaterialLight];
            g.userInteractionEnabled = NO;
            glass = g;
        }
        glass.translatesAutoresizingMaskIntoConstraints = NO;
        [view insertSubview:glass atIndex:0];
        [NSLayoutConstraint activateConstraints:@[
            [glass.leadingAnchor constraintEqualToAnchor:view.leadingAnchor],
            [glass.trailingAnchor constraintEqualToAnchor:view.trailingAnchor],
            [glass.topAnchor constraintEqualToAnchor:view.topAnchor],
            [glass.bottomAnchor constraintEqualToAnchor:view.bottomAnchor],
        ]];
        objc_setAssociatedObject(view, &kVGGlassBackdropTag, glass, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if ([glass isKindOfClass:VGDrawnGlassView.class]) {
        VGDrawnGlassView *g = (VGDrawnGlassView *)glass;
        g.dark = dark;
        [g setNeedsLayout];
    }
}

UIView *VGGlassBackdrop(UIView *view, BOOL dark) {
    if (!view || !VGLiquidEnabled()) return nil;
    UIView *g = [UIView new];
    g.userInteractionEnabled = NO;
    g.translatesAutoresizingMaskIntoConstraints = NO;
    [view insertSubview:g atIndex:0];
    [NSLayoutConstraint activateConstraints:@[
        [g.leadingAnchor constraintEqualToAnchor:view.leadingAnchor],
        [g.trailingAnchor constraintEqualToAnchor:view.trailingAnchor],
        [g.topAnchor constraintEqualToAnchor:view.topAnchor],
        [g.bottomAnchor constraintEqualToAnchor:view.bottomAnchor],
    ]];
    return g;
}

void VGStyleGlassButton(UIButton *button) {
    if (!button) return;
    if (HasRealGlass()) {
        // 26's own glass button: the glass capsule, with the accent kept for the icon.
        if (@available(iOS 26.0, *)) {
            UIGlassEffect *fx = (UIGlassEffect *)MakeGlassEffect(NO);
            if (fx) button.configuration = [UIButtonConfiguration glassButtonConfiguration];
        }
    }
}

#pragma mark - Screen edges

@interface VGGlassScreenEdges ()
@property (nonatomic, assign) UIRectCorner corners;
@property (nonatomic, assign) CGFloat radius;
@property (nonatomic, assign) BOOL showsTop, showsBottom;
@end

@implementation VGGlassScreenEdges

@synthesize corners = _corners, radius = _radius, showsTop = _showsTop, showsBottom = _showsBottom;

+ (instancetype)attachTo:(UIView *)container {
    if (!container) return nil;
    VGGlassScreenEdges *e = [[VGGlassScreenEdges alloc] initWithFrame:CGRectZero];
    e.userInteractionEnabled = NO;
    e.hidden = YES;
    e.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:e];
    [NSLayoutConstraint activateConstraints:@[
        [e.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [e.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
        [e.topAnchor constraintEqualToAnchor:container.topAnchor],
        [e.bottomAnchor constraintEqualToAnchor:container.bottomAnchor],
    ]];
    return e;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _radius = 26;
        _corners = 0;
    }
    return self;
}

- (void)setShowsTop:(BOOL)top bottom:(BOOL)bottom corners:(UIRectCorner)corners {
    if (self.showsTop == top && self.showsBottom == bottom && self.corners == corners) return;
    self.showsTop = top; self.showsBottom = bottom; self.corners = corners;
    self.hidden = !VGLiquidEnabled() || !(top || bottom);
    [self refresh];
}

@end

/// One corner of the screen, rounded: a quarter disc that cuts the square corner off the page.
/// (Clockwise arcs run left -> right, so the left and right corners are drawn in opposite directions.)
static UIBezierPath *CornerPunch(CGRect b, CGFloat r, BOOL left, BOOL top) {
    CGFloat cx = left ? r : b.size.width - r;
    CGFloat cy = top ? r : b.size.height - r;
    CGPoint c = CGPointMake(cx, cy);
    UIBezierPath *p = [UIBezierPath bezierPath];
    if (top && left) {
        [p moveToPoint:CGPointMake(0, r)];
        [p addArcWithCenter:c radius:r startAngle:M_PI_2 endAngle:M_PI clockwise:NO];
    } else if (top) {
        [p moveToPoint:CGPointMake(b.size.width - r, 0)];
        [p addArcWithCenter:c radius:r startAngle:-M_PI_2 endAngle:0 clockwise:YES];
    } else if (left) {
        [p moveToPoint:CGPointMake(0, cy)];
        [p addArcWithCenter:c radius:r startAngle:M_PI endAngle:M_PI_2 clockwise:YES];
    } else {
        [p moveToPoint:CGPointMake(b.size.width - r, b.size.height)];
        [p addArcWithCenter:c radius:r startAngle:M_PI_2 endAngle:0 clockwise:NO];
    }
    [p closePath];
    return p;
}
