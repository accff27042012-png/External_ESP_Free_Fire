#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

__attribute__((constructor)) static void init() {
    NSLog(@"[Hack] Loaded!");
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Hack" 
                                                                       message:@"OK" 
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [[UIApplication sharedApplication].keyWindow.rootViewController presentViewController:alert animated:YES completion:nil];
    });
}
