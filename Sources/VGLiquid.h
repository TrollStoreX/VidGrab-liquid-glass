#import <UIKit/UIKit.h>
#import "VGTheme.h"

// Liquid Glass: iOS 26's real glass material (UIGlassEffect) when the system has it, and a
// hand-drawn glass (blur + edge light + inner rim + depth) that looks the same everywhere else.
// Everything here works on iOS 15+ — on older systems only the drawn glass is used.

extern NSString *const VGGlassDidChangeNotification;

/// On: the glass look is used everywhere. Off is also what Reduce Transparency asks for.
extern BOOL VGLiquidEnabled(void);
/// Saves the switch (Settings > Liquid Glass) and rebuilds the pages with it.
extern void VGLiquidSetEnabled(BOOL on);
/// Starts following the system's Reduce Transparency switch. Called once at launch.
extern void VGLiquidListenForAccessibility(void);

/// Corner radius of the floating pieces. A little inside the system's 26, so our glass sits level with iOS 26's own.
#define VGGlassRadius 22.0

/// Real Liquid Glass (iOS 26 only). Before iOS 26 VGApplyGlass draws the glass itself instead.
@interface VGGlassView : UIVisualEffectView
/// Masked to the view's rounded corners (the bars are rounded on iOS 26).
@property (nonatomic, assign) BOOL roundTop, roundBottom;
/// Slightly stronger glass, for bars that sit over busy pages (Browse).
@property (nonatomic, assign) BOOL dense;
@end

/// Applies VidGrab's glass to an existing view: the glass goes at its back, the view keeps
/// its content. `radius` 0 keeps the view's own corner radius.
/// `dark` is for surfaces that always sit on video (the player): dark glass on every theme.
void VGApplyGlass(UIView *view, CGFloat radius, BOOL dark);
/// Takes the glass off again (the view goes back to its own background color).
void VGRemoveGlass(UIView *view);
/// YES when the view was given glass by VGApplyGlass.
BOOL VGHasGlass(UIView *view);

/// A plain frosted layer (no glass capsule), used behind sheets.
UIView *VGGlassBackdrop(UIView *view, BOOL dark);

/// The system's own buttons and labels over the glass (Liquid Glass on iOS 26).
void VGStyleBarItem(UIBarButtonItem *item);
void VGStyleNavigationBar(UINavigationBar *bar);

/// A round floating glass button (the browser's Download button).
void VGStyleGlassButton(UIButton *button);

/// Rounded screen edges on top of everything: bars round into the corners the way iOS 26 does.
@interface VGGlassScreenEdges : UIView
+ (instancetype)attachTo:(UIView *)container;
/// Which screen corners to round, and whether the bar edge is at the top or the bottom.
- (void)setShowsTop:(BOOL)top bottom:(BOOL)bottom corners:(UIRectCorner)corners;
/// Draws it again (after a theme change or a rotation).
- (void)refresh;
@end
