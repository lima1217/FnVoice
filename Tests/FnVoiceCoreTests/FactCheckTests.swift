import Foundation
import Testing
@testable import FnVoiceCore

@Suite struct FactCheckTests {
    func values(_ s: String, _ kind: FactCheck.Kind) -> [String] {
        FactCheck.facts(in: s).filter { $0.kind == kind }.map(\.value)
    }

    @Test func readsNumbersWrittenEitherWay() {
        #expect(values("预算五万，三点半开会", .number) == ["50000", "3", "30"])
        #expect(values("预算50000，3:30开会", .number) == ["50000", "3", "30"])
        #expect(values("二零二六年一百二十个", .number) == ["2026", "120"])
        #expect(values("版本2.3，涨了15%", .number) == ["2.3", "15"])
        #expect(values("两三天", .number) == ["2", "3"])
        #expect(values("三点十分", .number) == ["3", "10"])
    }

    @Test func ignoresNumeralsThatAreWords() {
        #expect(values("这个十分重要，一起看一下，千万别忘", .number).isEmpty)
        #expect(values("第一把周报写完，第三修bug", .number).isEmpty)
        #expect(values("要做两件事：\n1. 写周报\n2. 修bug", .number) == ["2"])
        #expect(values("发给张三，抄送李四和王五", .number).isEmpty)
    }

    @Test func aTextMayOpenWithACorrectionMarker() {
        #expect(FactCheck.check(source: "不对，周四开会", output: "周四开会").passed)
    }

    @Test func aLoneOneIsANumberOnlyBeforeAUnitOrAsAnHour() {
        #expect(values("一号到，花了一块，上午一点", .number) == ["1", "1", "1"])
        #expect(values("好一点，看一个，统一", .number).isEmpty)
    }

    @Test func readsDatesAndNegations() {
        #expect(values("下周三下午，礼拜五也行", .when) == ["下周", "W3", "下午", "W5"])
        #expect(values("周五别发版，也不用等我，没有通过", .negation).count == 3)
        #expect(values("不错，不过别人说的也不同", .negation).isEmpty)
        #expect(values("不对", .negation).isEmpty)
    }

    @Test func acceptsAFaithfulRewrite() {
        let src = "嗯帮我写个消息给张总就是说那个下周三下午三点开会然后预算是五万千万别迟到"
        let out = "张总您好：\n下周三下午3点开会，预算5万元，请千万不要迟到。"
        let r = FactCheck.check(source: src, output: out, keep: ["张总"])
        #expect(r.passed, "\(r.summary)")
    }

    @Test func catchesADroppedNegation() {
        let r = FactCheck.check(source: "周五别发版", output: "周五发版。")
        #expect(!r.passed)
        #expect(r.missing.contains { $0.kind == .negation })
    }

    @Test func catchesAnAddedNegation() {
        #expect(!FactCheck.check(source: "周五发版", output: "周五不发版。").passed)
    }

    @Test func catchesChangedAndInventedFacts() {
        let r = FactCheck.check(source: "三点开会", output: "4点开会，周二前回复")
        #expect(r.missing.map(\.value) == ["3"])
        #expect(Set(r.added.map(\.value)) == ["4", "W2"])
    }

    @Test func dropsTheValueASelfCorrectionAbandoned() {
        let good = FactCheck.check(source: "周三不对周四开会预算五万不对八万", output: "周四开会，预算8万。")
        #expect(good.passed, "\(good.summary)")
        let kept = FactCheck.check(source: "周三不对周四开会", output: "周三开会。")
        #expect(kept.superseded.map(\.value) == ["W3"])
        #expect(kept.missing.map(\.value) == ["W4"])
        let both = FactCheck.check(source: "用Redis不对应该是Memcached", output: "用Redis和Memcached")
        #expect(both.superseded.map(\.value) == ["redis"])
    }

    @Test func aCorrectionOnlyAbandonsTheSameKindOfFact() {
        // 明天 has no replacement after the marker, so it is still a fact to keep.
        let r = FactCheck.check(source: "明天和张总三点不对四点见", output: "四点和张总见。")
        #expect(r.missing.map(\.value) == ["明天"])
    }

    @Test func flagsATranslationAsAddedEnglish() {
        let r = FactCheck.check(source: "我们下周三上线", output: "We launch next Wednesday.")
        #expect(!r.passed)
        #expect(r.added.contains { $0.kind == .latin })
    }

    @Test func allowsVocabularyTermsAndChecksKeepAndDrop() {
        let fixed = FactCheck.check(source: "用配森写", output: "用Python写", vocabulary: ["Python"])
        #expect(fixed.passed, "\(fixed.summary)")
        let r = FactCheck.check(source: "发给李四", output: "发给张三", keep: ["李四"], drop: ["张三"])
        #expect(r.missingRequired == ["李四"] && r.forbidden == ["张三"])
    }

    @Test func everyRewriteReferenceInTheCorpusPassesAndTheRawInputFailsWhereItMust() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Eval/corpus.jsonl")
        let cases = try EvalCase.loadJSONL(String(contentsOf: url, encoding: .utf8)).filter { $0.kind == .rewrite }
        #expect(cases.count >= 20)
        for c in cases {
            let input = try #require(c.input)
            let r = FactCheck.check(source: input, output: c.reference, keep: c.keep ?? [], drop: c.drop ?? [])
            #expect(r.passed, "\(c.id) reference: \(r.summary)")
            // Self-corrections leave the abandoned value in the raw text, so typing it unchanged must fail.
            if c.category == "selfcorrect" {
                let raw = FactCheck.check(source: input, output: input, keep: c.keep ?? [], drop: c.drop ?? [])
                #expect(!raw.passed, "\(c.id): raw input should fail")
            }
        }
    }
}
