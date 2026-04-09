#import "SCIExcludedStoryUsers.h"
#import "../../Utils.h"

#define SCI_STORY_EXCL_KEY @"excluded_story_users"

@implementation SCIExcludedStoryUsers

+ (BOOL)isFeatureEnabled {
    return [SCIUtils getBoolPref:@"enable_story_user_exclusions"];
}

+ (NSArray<NSDictionary *> *)allEntries {
    NSArray *raw = [[NSUserDefaults standardUserDefaults] arrayForKey:SCI_STORY_EXCL_KEY];
    return raw ?: @[];
}

+ (NSUInteger)count { return [self allEntries].count; }

+ (void)saveAll:(NSArray *)entries {
    [[NSUserDefaults standardUserDefaults] setObject:entries forKey:SCI_STORY_EXCL_KEY];
}

+ (NSDictionary *)entryForPK:(NSString *)pk {
    if (pk.length == 0) return nil;
    for (NSDictionary *e in [self allEntries]) {
        if ([e[@"pk"] isEqualToString:pk]) return e;
    }
    return nil;
}

+ (BOOL)isUserPKExcluded:(NSString *)pk {
    if (![self isFeatureEnabled]) return NO;
    return [self entryForPK:pk] != nil;
}

+ (void)addOrUpdateEntry:(NSDictionary *)entry {
    NSString *pk = entry[@"pk"];
    if (pk.length == 0) return;
    NSMutableArray *all = [[self allEntries] mutableCopy];
    NSInteger existingIdx = -1;
    for (NSInteger i = 0; i < (NSInteger)all.count; i++) {
        if ([all[i][@"pk"] isEqualToString:pk]) { existingIdx = i; break; }
    }
    NSMutableDictionary *merged = [entry mutableCopy];
    if (existingIdx >= 0) {
        NSDictionary *old = all[existingIdx];
        if (old[@"addedAt"]) merged[@"addedAt"] = old[@"addedAt"];
        all[existingIdx] = merged;
    } else {
        if (!merged[@"addedAt"]) merged[@"addedAt"] = @([[NSDate date] timeIntervalSince1970]);
        [all addObject:merged];
    }
    [self saveAll:all];
}

+ (void)removePK:(NSString *)pk {
    if (pk.length == 0) return;
    NSMutableArray *all = [[self allEntries] mutableCopy];
    [all filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *e, id _) {
        return ![e[@"pk"] isEqualToString:pk];
    }]];
    [self saveAll:all];
}

@end
