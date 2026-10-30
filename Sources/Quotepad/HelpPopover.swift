import Cocoa

/// The `/help` card: slash commands, Markdown and shortcuts, in two aligned columns.
final class HelpViewController: NSViewController {
    private static let sections: [(String, [(String, String)])] = [
        ("명령어 (입력 후 Space 또는 Enter)", [
            ("/code", "코드 블록 · 언어 자동 인식"),
            ("/p", "한 줄 복사 박스"),
            ("/help", "이 도움말"),
            ("⌘, → 단축어", "나만의 단축어 추가"),
        ]),
        ("Markdown", [
            ("# 제목", "제목 (## ### 까지)"),
            ("**굵게**  *기울임*", "굵게 · 기울임"),
            ("~~취소~~  `코드`", "취소선 · 인라인 코드"),
            ("- 항목  1. 항목", "목록 · 번호 목록"),
            ("Tab  ⇧Tab", "목록 들여쓰기 · 내어쓰기 (사진·글은 항목 안으로)"),
            ("- [ ] 할 일", "체크리스트"),
            ("> 인용", "인용"),
            ("---", "구분선"),
            ("| a | b |", "표"),
            ("⌘V · 끌어놓기", "사진 넣기"),
            ("사진 클릭 → 양옆 끌기", "사진 크기 조절 (비율 유지)"),
        ]),
        ("단축키", [
            ("⌘'", "열기 / 닫기"),
            ("⌘T  ⌘W", "새 탭 · 탭 닫기"),
            ("⌃Tab  ⌘⇧]", "다음 탭"),
            ("⌥⌘←  ⌥⌘→", "이전 · 다음 탭"),
            ("⌘C  ⌘⇧C", "복사 (사진은 경로) · 사진째 복사 (Notion)"),
            ("⌘,", "설정"),
            ("Esc", "숨기기"),
        ]),
    ]

    override func loadView() {
        let content = Self.content()
        let inset = NSSize(width: 16, height: 12)
        let size = content.boundingRect(with: NSSize(width: 1000, height: 1000), options: [.usesLineFragmentOrigin]).size
        let label = NSTextField(labelWithAttributedString: content)
        label.frame = NSRect(x: inset.width, y: inset.height, width: ceil(size.width) + 4, height: ceil(size.height))
        view = NSView(frame: NSRect(x: 0, y: 0, width: label.frame.maxX + inset.width, height: label.frame.maxY + inset.height))
        view.addSubview(label)
        preferredContentSize = view.frame.size
    }

    private static func content() -> NSAttributedString {
        let keyFont = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .left, location: 150)]
        style.lineSpacing = 2
        let headerStyle = NSMutableParagraphStyle()
        headerStyle.paragraphSpacingBefore = 8
        headerStyle.paragraphSpacing = 3

        let result = NSMutableAttributedString()
        for (index, (title, rows)) in sections.enumerated() {
            if index > 0 { result.append(NSAttributedString(string: "\n")) }
            result.append(NSAttributedString(string: title + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: index == 0 ? NSParagraphStyle.default : headerStyle,
            ]))
            for (rowIndex, (key, meaning)) in rows.enumerated() {
                result.append(NSAttributedString(string: key, attributes: [
                    .font: keyFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: style,
                ]))
                let end = rowIndex == rows.count - 1 ? "" : "\n"
                result.append(NSAttributedString(string: "\t" + meaning + end, attributes: [
                    .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: style,
                ]))
            }
        }
        return result
    }
}
