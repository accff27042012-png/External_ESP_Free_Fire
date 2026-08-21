#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

__attribute__((constructor)) static void init() {
    NSLog(@"[Hack] Dylib loaded!");
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *window = [UIApplication sharedApplication].keyWindow;
        if (window) {
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Hack" 
                                                                           message:@"Loaded Successfully!" 
                                                                    preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            [window.rootViewController presentViewController:alert animated:YES completion:nil];
        }
    });
}
