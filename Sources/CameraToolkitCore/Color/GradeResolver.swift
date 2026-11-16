import Foundation

/// Turns a clip's stored grade (or none) into the recipe it is drawn with:
/// which profile it is read as, which conversion applies (the clip's own
/// choice, else its profile's default, else the built-in), and whether its
/// look can go on top. The app and the before-sync planner both use it, so
/// they always agree.
public struct GradeResolver: Sendable {
    public var defaults: GradeDefaults
    /// Imported LUTs that are present, with what each expects.
    public var lutRoles: [String: LUTRole]

    public init(defaults: GradeDefaults, lutRoles: [String: LUTRole]) {
        self.defaults = defaults
        self.lutRoles = lutRoles
    }

    public func profile(explicit: ClipGrade?, detected: LogProfile?) -> LogProfile? {
        (explicit?.profileMark ?? .detected).resolve(detected: detected)
    }

    /// The grade in effect: the clip's own, with its profile's default
    /// look when it has chosen none of its own and touched nothing.
    public func effectiveGrade(explicit: ClipGrade?, profile: LogProfile?) -> ClipGrade {
        var grade = explicit ?? ClipGrade()
        if let profile, grade.look == .none, grade.hasNeutralControls, let look = defaults.look(for: profile), isLook(look) {
            grade.look = look
            if explicit == nil || explicit?.intensity == 1 { grade.intensity = look.defaultIntensity }
        }
        return grade
    }

    /// True when `look` is a look (never a conversion LUT).
    public func isLook(_ look: GradeLook) -> Bool {
        switch look {
        case .none, .builtIn: true
        case .lut(let id): lutRoles[id] == .look
        }
    }

    /// True when `id` is a present conversion LUT for `profile`.
    public func isConversionLUT(_ id: String, for profile: LogProfile) -> Bool {
        lutRoles[id] == .conversion(profile)
    }

    public func conversion(for grade: ClipGrade, profile: LogProfile?) -> ResolvedConversion {
        guard let profile else { return .none }
        let choice = grade.conversion == .auto ? defaults.conversion(for: profile) : grade.conversion
        switch choice {
        case .off:
            return .none
        case .builtIn:
            return profile.hasBuiltInConversion ? .builtIn : .none
        case .lut(let id):
            if isConversionLUT(id, for: profile) { return .lut(id) }
            return profile.hasBuiltInConversion ? .builtIn : .none
        case .auto:
            return profile.hasBuiltInConversion ? .builtIn : .none
        }
    }

    /// The recipe, or nil when drawing it would change nothing (not log,
    /// no look, sliders at rest). A look LUT that is missing, or a LUT that
    /// is really a conversion, is dropped rather than stacked.
    public func recipe(explicit: ClipGrade?, detected: LogProfile?, range: VideoSignalRange) -> GradeRecipe? {
        let profile = profile(explicit: explicit, detected: detected)
        var grade = effectiveGrade(explicit: explicit, profile: profile)
        if !isLook(grade.look) { grade.look = .none }
        let recipe = GradeRecipe(grade: grade, profile: profile, conversion: conversion(for: grade, profile: profile), range: range)
        return recipe.isIdentity ? nil : recipe
    }
}
