#import <Foundation/Foundation.h>
#import "TelephonyProbe.h"

@interface CSTelephonyProbe (Tests)
+ (void)testClient:(id)client contextClass:(Class)contextClass continuing:(BOOL (^)(void))continuing update:(void (^)(NSArray *))update;
@end
static int checks;
static void Check(BOOL value, const char *message) {
    if (!value) { fprintf(stderr, "FAIL: %s\n", message); exit(1); }
    checks++;
}
@interface FakeContext : NSObject
@property int slot;
+ (id)contextWithSlot:(int)slot;
@end
@implementation FakeContext
+ (id)contextWithSlot:(int)slot { FakeContext *value = [self new]; value.slot = slot; return value; }
@end
@interface FakeValues : NSObject
- (BOOL)isRegisteredForVoice;
- (BOOL)isRegisteredForSMS;
- (BOOL)attached;
- (BOOL)newRadioSaDataBearer;
- (BOOL)newRadioNsaDataBearer;
@end
@implementation FakeValues
- (BOOL)isRegisteredForVoice { return NO; }
- (BOOL)isRegisteredForSMS { return YES; }
- (BOOL)attached { return YES; }
- (BOOL)newRadioSaDataBearer { return NO; }
- (BOOL)newRadioNsaDataBearer { return YES; }
@end
@interface FakeClient : NSObject
@property int calls;
- (id)getIMSRegistrationStatus:(FakeContext *)context error:(NSError **)error;
- (id)getActiveConnections:(FakeContext *)context error:(NSError **)error;
- (id)getDataStatus:(FakeContext *)context error:(NSError **)error;
@end
@implementation FakeClient
- (id)getIMSRegistrationStatus:(FakeContext *)context error:(NSError **)error {
    self.calls++;
    if (context.slot == 2) {
        *error = [NSError errorWithDomain:@"kCTErrorDomain" code:13 userInfo:@{NSLocalizedDescriptionKey: @"private IMSI"}];
        return [FakeValues new]; // Even an object accompanying an error is not usable data.
    }
    return [FakeValues new];
}
- (id)getActiveConnections:(FakeContext *)context error:(NSError **)error { self.calls++; return context.slot == 1 ? @[@"kCTDataConnectionServiceTypeIMS", @"secret"] : @[]; }
- (id)getDataStatus:(FakeContext *)context error:(NSError **)error { self.calls++; return context.slot == 1 ? [FakeValues new] : nil; }
@end
@interface WrongSignature : NSObject
@property BOOL invoked;
- (long long)getIMSRegistrationStatus:(id)context error:(NSError **)error;
- (id)getActiveConnections:(id)context error:(NSError **)error;
@end
@implementation WrongSignature
- (long long)getIMSRegistrationStatus:(id)context error:(NSError **)error { self.invoked = YES; return 0; }
- (id)getActiveConnections:(id)context error:(NSError **)error { [NSException raise:@"failure" format:@"private details"]; return nil; }
@end
static NSArray *Collect(id client) {
    __block NSArray *rows;
    [CSTelephonyProbe testClient:client contextClass:FakeContext.class continuing:^BOOL { return YES; } update:^(NSArray *value) { rows = value; }];
    return rows;
}
static NSDictionary *Row(NSArray *rows, int slot, NSString *metric) {
    for (NSDictionary *row in rows) if ([row[@"slot"] intValue] == slot && [row[@"metric"] isEqual:metric]) return row;
    return nil;
}
int main(void) {
    @autoreleasepool {
        FakeClient *client = [FakeClient new];
        NSArray *rows = Collect(client);
        Check(rows.count == 12 && client.calls == 6, "two explicit slot contexts and three requests per slot");
        Check([Row(rows, 1, @"imsVoice")[@"value"] isEqual:@NO], "false BOOL preserved");
        Check([Row(rows, 1, @"imsSMS")[@"value"] isEqual:@YES], "true BOOL preserved");
        Check([Row(rows, 2, @"imsVoice")[@"status"] isEqual:@"error"] && !Row(rows, 2, @"imsVoice")[@"value"], "NSError wins over accompanying object");
        Check([Row(rows, 2, @"imsVoice")[@"code"] isEqual:@13], "exact error code preserved");
        Check([Row(rows, 2, @"attached")[@"status"] isEqual:@"empty"], "nil status not false");
        Check([Row(rows, 1, @"imsConnection")[@"value"] isEqual:@YES] && [Row(rows, 2, @"imsConnection")[@"value"] isEqual:@NO], "IMS membership decoded independently per slot");
        Check(![[rows description] containsString:@"secret"] && ![[rows description] containsString:@"private IMSI"], "raw objects and error descriptions never leave bridge");
        WrongSignature *wrong = [WrongSignature new]; rows = Collect(wrong);
        Check(!wrong.invoked && [Row(rows, 1, @"imsVoice")[@"status"] isEqual:@"signature"], "mismatched return ABI never invoked");
        Check([Row(rows, 1, @"imsConnection")[@"status"] isEqual:@"exception"], "Objective-C exception becomes unavailable data");
        Check([Row(rows, 1, @"attached")[@"status"] isEqual:@"unsupported"], "missing selector safely skipped");
        FakeClient *cancelled = [FakeClient new]; __block BOOL keepGoing = YES; __block NSUInteger delivered = 0;
        [CSTelephonyProbe testClient:cancelled contextClass:FakeContext.class continuing:^BOOL { return keepGoing; } update:^(NSArray *value) { delivered = value.count; keepGoing = NO; }];
        Check(cancelled.calls == 1 && delivered == 2, "cancellation preserves partial results and skips remaining requests");
        printf("PASS: %d Objective-C runtime bridge checks\n", checks);
    }
}
