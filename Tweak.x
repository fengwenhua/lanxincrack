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

%end
