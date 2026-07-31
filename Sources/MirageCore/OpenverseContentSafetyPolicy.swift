import Foundation

/// 对 Openverse 的公开元数据做保守过滤，降低昆虫、节肢动物及不适医学或血腥内容的暴露风险。
enum OpenverseContentSafetyPolicy {
    /// 这些数据源以物种、标本或生物分类为主，服务端先排除可显著减少不适候选和无效下载。
    static let excludedAPISources = [
        "inaturalist",
        "animaldiversity",
        "bio_diversity",
        "phylopic",
        "smithsonian_national_museum_of_natural_history"
    ]

    /// Openverse 的 stats 会返回 `WoRMS`，但搜索接口会把它规范化为无效的 `worms`；仅在响应侧兜底排除。
    private static let normalizedExcludedSources = Set(
        (excludedAPISources + ["WoRMS"]).map { $0.lowercased() }
    )

    /// 精确按词过滤，避免 `ant` 误伤 `plant`、`fly` 误伤其他包含相同字母的单词。
    private static let excludedTokens: Set<String> = [
        "ant", "ants", "aphid", "aphids", "arachnid", "arachnids", "arachnida", "araneae",
        "arthropod", "arthropods", "arthropoda", "bee", "bees", "beetle", "beetles",
        "bedbug", "bedbugs", "blattoidea", "bug", "bugs", "butterfly", "butterflies",
        "caterpillar", "caterpillars", "centipede", "centipedes", "cicada", "cicadas",
        "cockroach", "cockroaches", "coleoptera", "cricket", "crickets", "damselfly", "damselflies",
        "diptera", "dragonfly", "dragonflies", "earwig", "earwigs", "firefly", "fireflies",
        "flea", "fleas", "fly", "flies", "gnat", "gnats",
        "grasshopper", "grasshoppers", "hemiptera", "hornet", "hornets", "hymenoptera",
        "housefly", "houseflies", "insect", "insects", "insecta", "ladybug", "ladybugs",
        "larva", "larvae", "leech", "leeches", "lepidoptera", "locust", "locusts", "louse", "lice",
        "maggot", "maggots", "mantis", "mantises", "mantodea", "mayfly", "mayflies",
        "millipede", "millipedes", "mite", "mites", "mosquito", "mosquitoes", "moth", "moths", "odonata",
        "orthoptera", "parasite", "parasites", "parasitic", "roach", "roaches", "scorpion", "scorpions",
        "silverfish", "slug", "slugs", "snail", "snails", "spider", "spiders", "stinkbug", "stinkbugs",
        "termite", "termites", "tick", "ticks", "wasp", "wasps", "weevil", "weevils", "worm", "worms",
        "amputated", "amputation", "autopsy", "beheaded", "beheading", "blood", "bloody",
        "cadaver", "cadavers", "carcass", "carcasses", "corpse", "corpses", "decapitated", "decapitation",
        "dissection", "gore", "gory", "infection", "infections", "injured", "injury", "mutilated", "mutilation",
        "lesion", "lesions", "skull", "skulls", "skeleton", "skeletons", "surgery", "surgical",
        "roadkill", "tumor", "tumors", "tumour", "tumours", "ulcer", "ulcers", "wound", "wounds"
    ]

    /// 中文等不使用空格分词的标题与标签改用保守片段匹配。
    private static let excludedFragments = [
        "昆虫", "节肢动物", "蜘蛛", "蟑螂", "蜈蚣", "蚰蜒", "蚊子", "蚊虫", "苍蝇",
        "甲虫", "毛毛虫", "幼虫", "蛆虫", "蝎子", "蜱虫", "跳蚤", "黄蜂", "马蜂",
        "蜜蜂", "蚂蚁", "萤火虫", "蚜虫", "蝉", "螳螂", "飞蛾", "蝴蝶", "寄生虫",
        "水蛭", "蛞蝓", "蜗牛", "血腥", "流血", "伤口", "尸体", "尸骸", "路杀",
        "解剖", "手术", "肿瘤", "溃疡", "病变", "骷髅", "头骨", "断头", "斩首", "肢解", "截肢"
    ]

    private static let excludedPhrases = [
        "animal carcass",
        "dead animal",
        "dead body",
        "human remains",
        "medical procedure",
        "open wound",
        "post mortem"
    ]

    /// 服务端过滤不是安全边界；响应仍需满足摄影类别、来源与主题三层约束。
    static func allows(
        title: String?,
        tags: [String],
        source: String?,
        category: String?
    ) -> Bool {
        guard category?.lowercased() == "photograph" else { return false }
        if let source, normalizedExcludedSources.contains(source.lowercased()) { return false }

        let values = [title].compactMap { $0 } + tags
        return values.allSatisfy(isAllowedText)
    }

    /// 同时检查分词、规范化短语和中文片段，未知文字默认放行以避免把过滤器变成来源白名单。
    private static func isAllowedText(_ value: String) -> Bool {
        let folded = value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        ).lowercased()
        guard !excludedFragments.contains(where: folded.contains) else { return false }

        let tokens = folded.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        guard Set(tokens).isDisjoint(with: excludedTokens) else { return false }

        let normalizedPhrase = tokens.joined(separator: " ")
        return !excludedPhrases.contains(where: normalizedPhrase.contains)
    }
}
