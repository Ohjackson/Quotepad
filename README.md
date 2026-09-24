# QuickMemo

macOS 메뉴바에 상주하는 오버레이 메모장. 전역 단축키로 어디서든 즉시 메모창을 띄우고 끌 수 있습니다 (Spotlight처럼 동작).

## 기능

- **⌘'** — 오버레이 메모 패널 토글 (전역 단축키, 어떤 앱에서든 동작)
- 여러 개의 탭을 만들어 메모를 분리해서 관리
  - **⌘T** — 새 탭 추가 (오버레이가 열려 있을 때)
  - **⌘W** — 현재 탭 닫기 (탭이 1개 남으면 닫히지 않음)
  - 탭 클릭으로 전환, 탭 오른쪽 × 버튼으로 닫기
  - 탭 제목은 메모 첫 줄에서 자동으로 표시됨
- 입력 내용은 자동 저장되며, 앱을 껐다 켜도 모든 탭이 유지됨
- **Esc** 또는 다른 곳 클릭 시 패널이 자동으로 숨겨짐
- Dock에 아이콘이 뜨지 않는 메뉴바 전용 앱 (상태바 아이콘에서 토글/새 탭/탭 닫기/종료 가능)

## 데이터 저장 위치

`~/Library/Application Support/QuickMemo/tabs.json`

## 빌드 & 실행

```bash
swift build -c release
./.build/release/QuickMemo &
```

## 로그인 시 자동 실행 (선택)

시스템 설정 > 일반 > 로그인 항목에 빌드된 `.build/release/QuickMemo` 실행 파일을 추가하면 로그인할 때마다 자동으로 켜집니다.

## 구조

- `Package.swift` — Swift Package Manager 매니페스트
- `Sources/QuickMemo/main.swift` — 앱 전체 구현 (AppKit, 전역 단축키는 Carbon HIToolbox 사용)
