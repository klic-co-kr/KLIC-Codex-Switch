# Codex Account Switcher

<p align="center">
  <strong>macOS 메뉴바에서 OpenAI Codex 계정을 한 번의 클릭으로 전환하세요.</strong>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Swift-5.9+-orange.svg?style=flat-square" alt="Swift"/>
  <img src="https://img.shields.io/badge/macOS-14.0+-black.svg?style=flat-square&logo=apple" alt="macOS"/>
  <img src="https://img.shields.io/badge/License-MIT-blue.svg?style=flat-square" alt="MIT License"/>
  <img src="https://img.shields.io/badge/Dependencies-none-brightgreen.svg?style=flat-square" alt="No Dependencies"/>
</p>

---

## 🤔 이게 뭔가요?

여러 개의 OpenAI 계정(회사용, 개인용 등)을 사용하시나요? 계정을 바꿀 때마다 로그아웃 → 로그인을 반복하셨나요?

**Codex Account Switcher**는 macOS 메뉴바에 앉아서, **클릭 한 번**으로 Codex 계정을 전환해줍니다.

---

## ✨ 주요 기능

| 기능 | 설명 |
|------|------|
| 🔄 **원클릭 전환** | 메뉴바 클릭 → 계정 선택 → 끝 |
| ➕ **쉬운 계정 추가** | 브라우저 로그인 또는 디바이스 코드 방식 지원 |
| 📊 **사용량 표시** | 5시간 / 주간 사용 한계를 메뉴바에서 실시간 확인 |
| 🏷️ **계정 별명** | `회사`, `개인`, `🚀` 등 원하는 이름으로 표시 |
| 🔒 **안전한 OAuth** | 공식 OAuth 2.0 PKCE 인증, 비밀번호 저장 없음 |
| ⚡ **가벼운 앱** | 외부 의존성 제로, 순수 Swift 300KB 미만 |

---

## 📦 설치 (3단계)

### 1단계: 다운로드
```bash
git clone https://github.com/klic-co-kr/KLIC-Codex-Switch.git
cd KLIC-Codex-Switch
```

### 2단계: 빌드
```bash
./build.sh
```
> `build/Codex Account Switcher.app` 파일이 생성됩니다.

### 3단계: 설치
```bash
./install.sh
```
> 앱이 `~/Applications`에 복사됩니다.

---

## 🚀 사용법

### 처음 실행하기

1. 앱을 실행하면 메뉴바에 아이콘이 나타납니다
2. 클릭 → **"Add Account (Browser)"** 선택
3. 브라우저에서 OpenAI 로그인 → 완료!
4. 추가할 계정만큼 반복

### 계정 전환하기

1. 메뉴바 클릭
2. 전환할 계정 클릭
3. Codex 앱이 자동으로 재시작되며 새 계정으로 연결됩니다

### 계정 이름 변경하기

메뉴에서 계정 이름을 **"회사"**, **"개인"**, **"🚀"** 등으로 바꿀 수 있습니다.

---

## 🛠️ 개발자용

### 빌드 없이 바로 실행 (테스트용)
```bash
./run.sh
```

### 기술 스택
- **언어**: Swift 5.9+
- **플랫폼**: macOS 14.0+ (Sonoma)
- **의존성**: 없음 (순수 Swift + AppKit)
- **인증**: OAuth 2.0 PKCE

### CLI 명령어
```bash
# 현재 계정 목록
./run.sh -- list

# 계정 전환
./run.sh -- switch <이메일>

# 사용량 확인
./run.sh -- usage

# 자동 전환 설정
./run.sh -- rotation <on|off>
```

---

## 📁 프로젝트 구조

```
KLIC-Codex-Switcher/
├── Sources/
│   └── main.swift          # 전체 소스코드 (단일 파일)
├── Resources/
│   ├── en.lproj/           # 영어 로컬라이제이션
│   └── ko.lproj/           # 한국어 로컬라이제이션
├── build.sh                # 빌드 스크립트
├── install.sh              # 설치 스크립트
├── run.sh                  # 테스트 실행 스크립트
└── docs/                   # 설계 문서
```

---

## ❓ 자주 묻는 질문

**Q: 비밀번호가 저장되나요?**
A: 아니요. OAuth 토큰만 로컬에 저장되며, 비밀번호는 절대 저장하지 않습니다.

**Q: 어느 폴더에 데이터가 저장되나요?**
A: `~/.codex/` 폴더에 계정 정보가 저장됩니다.

**Q: Codex CLI도 같이 전환되나요?**
A: 네, Codex CLI와 Codex 데스크톱 앱 모두 동일한 계정으로 전환됩니다.

**Q: 최대 몇 개의 계정을 추가할 수 있나요?**
A: 제한이 없습니다.

---

## 📝 라이선스

MIT License. 자세한 내용은 [LICENSE](LICENSE) 파일을 참고하세요.
