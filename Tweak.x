%hook sub_1000010100215841

+ (BOOL)sub_1000010100215849 {
	return NO;
}

+ (void)sub_1000010100215846 {
}

+ (void)sub_1000010100215842 {
}

+ (void)sub_1000010100215847 {
}

+ (void)sub_1000010100215845 {
}

%end

%hook IMCoreMessage

- (int)msgState {
	int state = %orig;
	if (state == 6 || state == 7) {
		return 5;
	}
	return state;
}

- (void)setMsgState:(int)state {
	if (state == 6 || state == 7) {
		return;
	}
	%orig(state);
}

%end

%hook sub_1000010100215832

+ (BOOL)sub_1000010100215833 {
	return NO;
}

+ (BOOL)sub_1000010100215834 {
	return NO;
}

+ (BOOL)sub_1000010100215837 {
	return NO;
}

%end

%hook sub_2105813100215866

+ (BOOL)autoCheck {
	return NO;
}

%end

%hook sub_1000010100215866

+ (BOOL)sub_1000010100215867:(id)arg1 {
	return NO;
}

%end

%hook sub_3108813100215323

+ (void)autocheck {
}

+ (void)checkRoot {
}

%end

%hook CoreMessUtils

+ (BOOL)isJailBreak {
	return NO;
}

+ (BOOL)isJailBreak1 {
	return NO;
}

+ (BOOL)isJailBreak2 {
	return NO;
}

+ (BOOL)isJailBreak3 {
	return NO;
}

+ (BOOL)isJailBreak4 {
	return NO;
}

+ (BOOL)isJailBreak5 {
	return NO;
}

+ (BOOL)isJailBreak6 {
	return NO;
}

+ (BOOL)isJailBreak7 {
	return NO;
}

+ (BOOL)isJailBreak8 {
	return NO;
}

%end
