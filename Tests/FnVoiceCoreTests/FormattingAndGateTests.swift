import Testing
@testable import FnVoiceCore

@Suite struct TextFormatterTests {
    @Test(arguments: [
        // SpeechTranscriber output (space before only) and legacy output (no spaces) converge.
        ("我在用 Python写一个 JSON解析器。", "我在用 Python 写一个 JSON 解析器。"),
        ("我在用Python写一个JSON解析器", "我在用 Python 写一个 JSON 解析器"),
        ("用 Python 写", "用 Python 写"),
        ("这个 PR我已经 review过了。", "这个 PR 我已经 review 过了。"),
        // Multi-word and punctuated English stays intact.
        ("在 VS Code里装一个插件", "在 VS Code 里装一个插件"),
        ("用Node.js写服务器", "用 Node.js 写服务器"),
        ("C++和C#哪个快", "C++ 和 C# 哪个快"),
        ("升级到iOS17了", "升级到 iOS17 了"),
        // Numbers attach to Chinese.
        ("改成 5分钟", "改成5分钟"),
        ("明天下午 3点开会", "明天下午3点开会"),
        ("下午3:00开会", "下午3:00开会"),
        // No space next to full-width punctuation; stray spaces between Han removed.
        ("用 Python，然后 JSON。", "用 Python，然后 JSON。"),
        ("写代码 ？", "写代码？"),
        ("你 好", "你好"),
        ("“Python”很好", "“Python”很好"),
        // English and Korean spacing untouched.
        ("I think the API design looks good.", "I think the API design looks good."),
        ("Let's  ship it.", "Let's ship it."),
        ("안녕하세요 반갑습니다", "안녕하세요 반갑습니다"),
        // Japanese behaves like Chinese.
        ("これはPythonです", "これは Python です"),
        ("", ""),
    ])
    func formats(input: String, expected: String) {
        #expect(TextFormatter.format(input) == expected)
    }

    @Test func idempotent() {
        for s in ["我在用 Python写", "这个PR我review过了", "改成 5分钟。", "Hello world"] {
            let once = TextFormatter.format(s)
            #expect(TextFormatter.format(once) == once)
        }
    }

    @Test func doesNotChangeCharactersOnlySpaces() {
        let s = "我在用 piston写一个 JSON解析器。改成 5分钟"
        #expect(TextFormatter.format(s).filter { !$0.isWhitespace } == s.filter { !$0.isWhitespace })
    }
}

@Suite struct ListFormattingTests {
    @Test func keepsLineBreaksAndListNumberSpacing() {
        let list = "明天要做三件事：\n1. 把周报写完\n2. 跟产品对一下需求\n3. 把那个 bug修掉"
        #expect(TextFormatter.format(list) == "明天要做三件事：\n1. 把周报写完\n2. 跟产品对一下需求\n3. 把那个 bug 修掉")
        #expect(TextFormatter.format("第一行  \n  第二行") == "第一行\n第二行")
        // Not a list: a number mid-line keeps the Chinese no-space rule.
        #expect(TextFormatter.format("版本 1. 好的") == "版本1.好的")
    }
}

@Suite struct RefinementGateTests {
    @Test func englishOrSoundAlikesGoToTheLLM() {
        #expect(RefinementGate.shouldRefine("我在用 piston写"))
        #expect(RefinementGate.shouldRefine("我在用配森写"))
        #expect(RefinementGate.shouldRefine("Let's ship it"))
    }

    @Test func pureChineseSkipsTheLLM() {
        #expect(!RefinementGate.shouldRefine("今天天气不错，我们出去走走吧。"))
        #expect(!RefinementGate.shouldRefine("改成5分钟"))
        #expect(!RefinementGate.shouldRefine(""))
    }

    @Test func obviousDisfluencyGoesToTheLLM() {
        #expect(RefinementGate.shouldRefine("嗯我觉得可以"))
        #expect(RefinementGate.shouldRefine("周三不对周四开会"))
        #expect(!RefinementGate.shouldRefine("那个文件就是他发的"))
    }
}

@Suite struct VocabularyPromptTests {
    @Test func appendsTermsAfterBasePrompt() {
        let p = RefinementPrompt.system(vocabulary: ["FnVoice", "Kubernetes"])
        #expect(p.hasPrefix(RefinementPrompt.system))
        #expect(p.hasSuffix("FnVoice, Kubernetes"))
        #expect(p.contains("Never insert a term that wasn't spoken"))
    }

    @Test func emptyVocabularyIsBasePrompt() {
        #expect(RefinementPrompt.system(vocabulary: []) == RefinementPrompt.system)
    }
}
