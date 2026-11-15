#import "TelephonyProbe.h"
#import <string.h>

// API names/signatures are documented in docs/DEVELOPMENT.md. No private headers are linked.
static const char *CSType(const char *type) {
    while (*type && strchr("rnNoORV", *type)) type++;
    return type;
}
static BOOL CSObjectType(const char *type) {
    type = CSType(type);
    return *type == '@' && type[1] != '?';
}
static NSDictionary *CSIssue(NSString *status) { return @{ @"status": status }; }
static NSDictionary *CSError(NSError *error) {
    // Never forward localizedDescription, userInfo, subscription IDs or arbitrary domains.
    NSSet *domains = [NSSet setWithArray:@[@"kCTErrorDomain", @"CTErrorDomain", @"NSCocoaErrorDomain", @"NSPOSIXErrorDomain", @"NSOSStatusErrorDomain"]];
    NSString *domain = [domains containsObject:error.domain] ? error.domain : @"other";
    return @{ @"status": @"error", @"domain": domain, @"code": @(error.code) };
}

/// Supports only object-returning getters, optionally with a context and NSError**.
static id CSRead(id target, NSString *name, id context, BOOL hasContext, BOOL hasError, NSDictionary **issue) {
    *issue = nil;
    @try {
        SEL selector = NSSelectorFromString(name);
        if (!target || ![target respondsToSelector:selector]) { *issue = CSIssue(@"unsupported"); return nil; }
        NSMethodSignature *signature = [target methodSignatureForSelector:selector];
        NSUInteger count = 2 + hasContext + hasError;
        if (!signature || signature.numberOfArguments != count || !CSObjectType(signature.methodReturnType)
            || signature.methodReturnLength != sizeof(id)
            || (hasContext && !CSObjectType([signature getArgumentTypeAtIndex:2]))) {
            *issue = CSIssue(@"signature"); return nil;
        }
        if (hasError) {
            const char *type = CSType([signature getArgumentTypeAtIndex:count - 1]);
            if (*type != '^' || !CSObjectType(type + 1)) { *issue = CSIssue(@"signature"); return nil; }
        }
        NSInvocation *call = [NSInvocation invocationWithMethodSignature:signature];
        call.target = target; call.selector = selector;
        if (hasContext) { __unsafe_unretained id argument = context; [call setArgument:&argument atIndex:2]; }
        NSError *__autoreleasing error = nil;
        NSError *__autoreleasing *errorPointer = &error;
        if (hasError) [call setArgument:&errorPointer atIndex:count - 1];
        [call invoke];
        if (error) { *issue = CSError(error); return nil; }
        __unsafe_unretained id returned = nil;
        [call getReturnValue:&returned];
        id result = returned;
        if (!result) *issue = CSIssue(@"empty");
        return result;
    } @catch (__unused NSException *exception) {
        *issue = CSIssue(@"exception"); return nil;
    }
}

static NSNumber *CSBool(id target, NSString *name, NSDictionary **issue) {
    *issue = nil;
    @try {
        SEL selector = NSSelectorFromString(name);
        if (!target || ![target respondsToSelector:selector]) { *issue = CSIssue(@"unsupported"); return nil; }
        NSMethodSignature *signature = [target methodSignatureForSelector:selector];
        const char *type = signature ? CSType(signature.methodReturnType) : "";
        if (!signature || signature.numberOfArguments != 2 || signature.methodReturnLength != 1
            || (strcmp(type, "B") && strcmp(type, "c"))) { *issue = CSIssue(@"signature"); return nil; }
        NSInvocation *call = [NSInvocation invocationWithMethodSignature:signature];
        call.target = target; call.selector = selector; [call invoke];
        unsigned char value = 0; [call getReturnValue:&value];
        if (value > 1) { *issue = CSIssue(@"invalid"); return nil; }
        return @(value == 1);
    } @catch (__unused NSException *exception) { *issue = CSIssue(@"exception"); return nil; }
}

static id CSContext(Class type, int slot, NSDictionary **issue) {
    *issue = nil;
    @try {
        SEL selector = NSSelectorFromString(@"contextWithSlot:");
        if (!type || ![type respondsToSelector:selector]) { *issue = CSIssue(@"unsupported"); return nil; }
        NSMethodSignature *signature = [type methodSignatureForSelector:selector];
        if (!signature || signature.numberOfArguments != 3 || !CSObjectType(signature.methodReturnType)
            || signature.methodReturnLength != sizeof(id)) { *issue = CSIssue(@"signature"); return nil; }
        const char *argumentType = CSType([signature getArgumentTypeAtIndex:2]);
        if (strcmp(argumentType, "i") && strcmp(argumentType, "q")) { *issue = CSIssue(@"signature"); return nil; }
        NSInvocation *call = [NSInvocation invocationWithMethodSignature:signature];
        call.target = type; call.selector = selector;
        long long wideSlot = slot;
        if (!strcmp(argumentType, "i")) [call setArgument:&slot atIndex:2];
        else [call setArgument:&wideSlot atIndex:2];
        [call invoke];
        __unsafe_unretained id returned = nil; [call getReturnValue:&returned];
        id result = returned;
        if (!result) *issue = CSIssue(@"empty");
        return result;
    } @catch (__unused NSException *exception) { *issue = CSIssue(@"exception"); return nil; }
}

static NSDictionary *CSRow(int slot, NSString *metric, NSString *api, NSNumber *value, NSDictionary *issue) {
    NSMutableDictionary *row = [@{ @"slot": @(slot), @"metric": metric, @"api": api, @"date": [NSDate date] } mutableCopy];
    if (issue) [row addEntriesFromDictionary:issue];
    else if (value) { row[@"status"] = @"value"; row[@"value"] = value; }
    else row[@"status"] = @"empty";
    return row;
}

static void CSCollect(id client, Class contextClass, BOOL (^shouldContinue)(void), void (^update)(NSArray *)) {
    NSMutableArray *rows = [NSMutableArray array];
    // These are explicit CoreTelephony slot requests, never sorted public service identifiers.
    for (int slot = 1; slot <= 2 && shouldContinue(); slot++) {
        NSDictionary *issue = nil;
        id context = CSContext(contextClass, slot, &issue);
        if (!context) {
            [rows addObject:CSRow(slot, @"context", @"contextWithSlot:", nil, issue)]; update([rows copy]); continue;
        }
        for (NSString *api in @[@"getIMSRegistrationStatus:error:", @"getActiveConnections:error:", @"getDataStatus:error:"]) {
            if (!shouldContinue()) return;
            id result = CSRead(client, api, context, YES, YES, &issue);
            if ([api isEqualToString:@"getActiveConnections:error:"]) {
                NSNumber *present = nil;
                if (result) {
                    if (![result isKindOfClass:NSArray.class] || [result count] > 64) issue = CSIssue(@"invalid");
                    else {
                        BOOL valid = YES;
                        for (id item in result) if (![item isKindOfClass:NSString.class]) { valid = NO; break; }
                        if (valid) present = @([result containsObject:@"kCTDataConnectionServiceTypeIMS"]);
                        else issue = CSIssue(@"invalid");
                    }
                }
                [rows addObject:CSRow(slot, @"imsConnection", api, present, issue)];
            } else {
                NSArray *fields = [api isEqualToString:@"getIMSRegistrationStatus:error:"]
                    ? @[@[@"imsVoice", @"isRegisteredForVoice"], @[@"imsSMS", @"isRegisteredForSMS"]]
                    : @[@[@"attached", @"attached"], @[@"nrSA", @"newRadioSaDataBearer"], @[@"nrNSA", @"newRadioNsaDataBearer"]];
                for (NSArray *field in fields) {
                    NSDictionary *fieldIssue = issue;
                    NSNumber *value = result ? CSBool(result, field[1], &fieldIssue) : nil;
                    [rows addObject:CSRow(slot, field[0], [api stringByAppendingFormat:@"/%@", field[1]], value, fieldIssue)];
                }
            }
            update([rows copy]);
        }
    }
}

@implementation CSTelephonyProbe
+ (void)collectWhile:(BOOL (^)(void))shouldContinue update:(void (^)(NSArray<NSDictionary<NSString *,id> *> *))update {
    @autoreleasepool {
        @try {
            Class type = NSClassFromString(@"CoreTelephonyClient");
            if (!type) { update(@[CSRow(0, @"context", @"CoreTelephonyClient", nil, CSIssue(@"unsupported"))]); return; }
            id client = [[type alloc] init];
            CSCollect(client, NSClassFromString(@"CTXPCServiceSubscriptionContext"), shouldContinue, update);
        } @catch (__unused NSException *exception) {
            update(@[CSRow(0, @"context", @"CoreTelephonyClient", nil, CSIssue(@"exception"))]);
        }
    }
}
#if CS_TELEPHONY_TESTING
+ (void)testClient:(id)client contextClass:(Class)contextClass continuing:(BOOL (^)(void))continuing update:(void (^)(NSArray *))update {
    CSCollect(client, contextClass, continuing, update);
}
#endif
@end
