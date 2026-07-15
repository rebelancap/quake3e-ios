// ios_input.h — the input-owning game view (CAMetalLayer-backed) and the
// per-frame input hook. Implementation in ios_input.m; engine-side shims
// it calls live in ios_glue.c.
#import <UIKit/UIKit.h>

@interface Q3EInputView : UIView
@end

#ifdef __cplusplus
extern "C" {
#endif
void Q3E_Input_Frame(void); // called once per engine frame (main thread)
#ifdef __cplusplus
}
#endif
