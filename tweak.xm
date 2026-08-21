#import <UIKit/UIKit.h>

__attribute__((constructor)) static void init() {
    NSLog(@"[Hack] Loaded!");
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"Hack" 
                                                         message:@"Loaded Successfully!" 
                                                        delegate:nil 
                                               cancelButtonTitle:@"OK" 
                                               otherButtonTitles:nil];
        [alert show];
    });
}
