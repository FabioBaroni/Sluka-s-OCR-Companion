enum NuanceTag: String, CaseIterable {
    case none
    case lostInTranslation
    case culturalContext
}

struct SenseChoice {
    var senseNumber: Int
    var meaningHere: String
    var tag: NuanceTag = .none
    var note: String = ""
    /// True when the model refused and the sense was matched to a translation instead.
    var viaTranslation = false
}


func headlineGloss(_ sense: Sense) -> String { Gloss.short(sense.gloss) }
