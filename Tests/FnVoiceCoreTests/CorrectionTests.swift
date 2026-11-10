import Testing
@testable import FnVoiceCore

@Suite struct EditRegionTests {
    @Test func unchangedFieldReturnsPasted() {
        #expect(EditRegion.edited(before: "前文我在写带码", after: "前文我在写带码", range: 2..<7) == "我在写带码")
    }

    @Test func editInsidePastedSpan() {
        #expect(EditRegion.edited(before: "前文我在写带码。后文", after: "前文我在写代码。后文", range: 2..<8) == "我在写代码。")
    }

    @Test func editLengthChangeInsideSpan() {
        #expect(EditRegion.edited(before: "x我用杰森格式", after: "x我用JSON格式", range: 1..<7) == "我用JSON格式")
    }

    @Test func typingAfterPastedTextIsIgnored() {
        #expect(EditRegion.edited(before: "我在写带码", after: "我在写带码，谢谢", range: 0..<5) == "我在写带码")
    }

    @Test func typingBeforePastedTextIsIgnored() {
        #expect(EditRegion.edited(before: "AB我在写带码", after: "ABC我在写带码", range: 2..<7) == "我在写带码")
    }

    @Test func clearedFieldIsUnknown() {
        #expect(EditRegion.edited(before: "前文我在写带码", after: "", range: 2..<7) == nil)
    }

    @Test func editsSpanningOutsideAreUnknown() {
        #expect(EditRegion.edited(before: "前文我在写带码", after: "后来我在写代码", range: 2..<7) == nil)
    }
}

@Suite struct CorrectionExtractorTests {
    @Test func singleHanFixIsWidenedToAWord() {
        #expect(CorrectionExtractor.extract(pasted: "我在写带码", edited: "我在写代码")
            == [Correction(wrong: "带码", right: "代码")])
    }

    @Test func soundAlikeToTerm() {
        #expect(CorrectionExtractor.extract(pasted: "我用杰森格式存数据", edited: "我用 JSON 格式存数据")
            == [Correction(wrong: "杰森", right: "JSON")])
    }

    @Test func latinWordFixStandsAlone() {
        #expect(CorrectionExtractor.extract(pasted: "open the jason file", edited: "open the JSON file")
            == [Correction(wrong: "jason", right: "JSON")])
    }

    @Test func punctuationOnlyEditsAreIgnored() {
        #expect(CorrectionExtractor.extract(pasted: "好的，我知道了", edited: "好的。我知道了").isEmpty)
    }

    @Test func pureInsertionsAndDeletionsAreIgnored() {
        #expect(CorrectionExtractor.extract(pasted: "我知道了", edited: "我真的知道了").isEmpty)
        #expect(CorrectionExtractor.extract(pasted: "我真的知道了", edited: "我知道了").isEmpty)
    }

    @Test func rewritesAreIgnored() {
        #expect(CorrectionExtractor.extract(pasted: "明天开会", edited: "下周再说吧").isEmpty)
    }

    @Test func unchangedTextYieldsNothing() {
        #expect(CorrectionExtractor.extract(pasted: "我在写代码", edited: "我在写代码").isEmpty)
    }

    @Test func isolatedHanCharWithNoWordNeighbourIsDropped() {
        #expect(CorrectionExtractor.extract(pasted: "好，带，好", edited: "好，代，好").isEmpty)
    }
}

@Suite struct CorrectionStoreTests {
    let fix = Correction(wrong: "带码", right: "代码")

    @Test func appliesOnlyAfterConfirmation() {
        var store = CorrectionStore()
        #expect(store.record([fix]).isEmpty)
        #expect(store.apply("我在写带码") == "我在写带码")
        #expect(store.mentionsKnownMistake("我在写带码"))
        #expect(store.record([fix]) == [fix])
        #expect(store.apply("我在写带码") == "我在写代码")
    }

    @Test func revertingUnlearns() {
        var store = CorrectionStore()
        store.record([fix, fix])
        store.record([Correction(wrong: "代码", right: "带码")])
        #expect(store.apply("我在写带码") == "我在写带码")
        #expect(store.entries.first?.count == 1)
    }

    @Test func latinRulesMatchWholeWords() {
        let store = CorrectionStore(entries: [.init(correction: Correction(wrong: "jason", right: "JSON"), count: 2)])
        #expect(store.apply("parse the jason file") == "parse the JSON file")
        #expect(store.apply("jasonette") == "jasonette")
    }

    @Test func leavesTextThatAlreadyReadsRight() {
        let store = CorrectionStore(entries: [.init(correction: Correction(wrong: "明白", right: "不明白"), count: 3)])
        #expect(store.apply("我不明白") == "我不明白")
        #expect(store.apply("我明白") == "我不明白")
    }

    @Test func roundTripsThroughFile() {
        var store = CorrectionStore()
        store.record([fix, fix, Correction(wrong: "杰森", right: "JSON")])
        let parsed = CorrectionStore.parse(store.serialized())
        #expect(parsed == store)
        #expect(CorrectionStore.parse("# c\n\n带码 → 代码\n坏行\n").entries.map(\.count) == [1])
    }

    @Test func neverStoresWhatTheFileCantReadBack() {
        var store = CorrectionStore()
        store.record([
            Correction(wrong: "A→B", right: "AB"), Correction(wrong: "第一行\n第二行", right: "一行"),
            Correction(wrong: "x\ty", right: "xy"), Correction(wrong: " 带码", right: "代码"), fix,
        ])
        #expect(store.entries.map(\.correction) == [fix])
        #expect(CorrectionStore.parse(store.serialized()) == store)
    }

    @Test func dropsPairsThatCantMatchTheTypedText() {
        // "a, b" rebuilt from tokens reads "a,b", which is nowhere in what was typed.
        let pasted = "今天我们用 foo, bar 做一个小测试吧"
        let found = CorrectionExtractor.extract(pasted: pasted, edited: "今天我们用 foobar 做一个小测试吧")
        #expect(!found.contains { $0.wrong == "foo,bar" })
        #expect(found.allSatisfy { pasted.contains($0.wrong) })
    }

    @Test func vocabularyAndHints() {
        var store = CorrectionStore()
        store.record([fix, Correction(wrong: "杰森", right: "JSON")])
        #expect(Set(store.vocabularyTerms()) == ["代码", "JSON"])
        #expect(store.hints().count == 2)
        #expect(RefinementPrompt.system(vocabulary: [], corrections: [fix]).contains("带码 → 代码"))
    }

    @Test func contentEditsAreNoVocabulary() {
        let store = CorrectionStore.parse("50 → 30\n要，这 → 要3）这\n盖尔 → gall\nEBUB → EPUB\n")
        #expect(store.vocabularyTerms() == ["gall", "EPUB"])
    }

    @Test func handKeptVocabularyWinsOverLearnedSpelling() {
        let store = CorrectionStore.parse(
            "intowinger → interwingle\t2\nClaude → global\ngethave → github\n杰森 → JSON\nlima → llm\n"
        )
        let aligned = store.aligned(with: ["intertwingle", "Claude", "GitHub", "LLM"])
        #expect(aligned.entries.map(\.correction) == [
            Correction(wrong: "intowinger", right: "intertwingle"),
            Correction(wrong: "gethave", right: "GitHub"),
            Correction(wrong: "杰森", right: "JSON"),
            Correction(wrong: "lima", right: "LLM"),
        ])
        #expect(aligned.apply("打开 intowinger") == "打开 intertwingle")
        // Unrelated words stay as learned.
        #expect(CorrectionStore.vocabularySpelling(of: "global", in: ["Claude", "GitLab"]) == nil)
        #expect(CorrectionStore.editDistance("interwingle", "intertwingle") == 1)
    }
}
