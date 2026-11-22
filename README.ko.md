<p align="center">
  <img src="docs/assets/icon.png" width="116" height="116" alt="halo 앱 아이콘" />
</p>

<h1 align="center">halo</h1>

<p align="center">
  <strong>마우스 커서 위치 기반 화면별 밝기 조절과 원클릭 HiDPI를 하나로 묶은 경량 네이티브 macOS 메뉴바 앱</strong>
</p>

<p align="center">
  <a href="https://github.com/isnow890/halo/actions/workflows/ci.yml"><img src="https://img.shields.io/github/actions/workflow/status/isnow890/halo/ci.yml?label=build&style=flat-square" alt="CI Build" /></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-000000?style=flat-square&logo=apple&logoColor=white" alt="macOS 14+" />
  <img src="https://img.shields.io/badge/Apple%20Silicon-arm64-3ee6be?style=flat-square" alt="Apple Silicon" />
  <img src="https://img.shields.io/badge/Swift-6-F05138?style=flat-square&logo=swift&logoColor=white" alt="Swift 6" />
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue?style=flat-square" alt="MIT License" /></a>
</p>

<p align="center">
  <a href="README.md">English</a> · <strong>한국어</strong>
</p>

---

## 소개

**halo**는 **MonitorControl**과 **BetterDisplay**에서 실제로 가장 자주 쓰는 핵심 기능만 뽑아, 외부 의존성 없이 순수 **Swift(SwiftUI + AppKit + Objective-C 브릿지)**로 만든 가벼운 macOS 메뉴바 유틸리티입니다.

- **마우스 커서 위치 기반 밝기 키**: `F1` / `F2`, `F14` / `F15`, `⌃⌥↑` / `⌃⌥↓` 입력 시 **현재 마우스 커서가 올라가 있는 디스플레이**만 조절하며(모든 화면 / 메인 화면 전환 가능), 해당 화면 하단에 120Hz 부드러운 OSD HUD를 띄웁니다.
- **3단계 화면별 밝기 제어 엔진**:
  - **Native (`DisplayServices`)**: MacBook 내장 Liquid Retina / XDR 및 Apple 호환 디스플레이
  - **하드웨어 DDC/CI (`IOAVService`)**: Apple Silicon 외장 모니터 백라이트 직접 제어 (포트별 직렬 큐 및 VCP 응답·재조회 검증)
  - **소프트웨어 디밍 (Overlay / Gamma LUT)**: DisplayLink 독, DDC 미지원 휴대용 모니터 자동 폴백
- **안전한 HiDPI & 주사율 전환**: 숨겨진 HiDPI/LoDPI 해상도와 소수 주사율(`59.94Hz`, `47.95Hz`, `120Hz`, `130Hz` 등)을 지원하며, **15초 자동 복구 미리보기**로 미지원 해상도 고착을 방지합니다.
- **원클릭 가상 HiDPI 미러링 (`CGVirtualDisplay`)**: SIP 해제나 재부팅 없이 비-Retina 외장 모니터(세로 회전 포함)에 선명한 2× HiDPI 스케일링을 적용합니다.
- **호버 화면 식별 & Display Override 내보내기**: 카드 헤더에 마우스를 올리면 해당 모니터에 위치를 표시해 주며, 영구 네이티브 HiDPI용 `scale-resolutions` `.plist` 파일 내보내기를 지원합니다.
- **내장 업데이트 확인**: 외부 프레임워크 없이 GitHub Releases 최신 버전을 확인합니다(설정에서 언제든 끌 수 있음).

### 한눈에 비교

| 기능 | halo | MonitorControl | BetterDisplay |
| :--- | :---: | :---: | :---: |
| 커서 위치 기반 밝기 키 + 해당 화면 HUD | ✅ | ✅ | ✅ |
| Native + Apple Silicon DDC/CI + SW 폴백 | ✅ | ✅ | ✅ |
| 네이티브 HiDPI 및 소수 주사율 전환 | ✅ | — | ✅ |
| 원클릭 가상 HiDPI 미러링 (`CGVirtualDisplay`) | ✅ | — | ✅ (유료 Pro) |
| 15초 해상도 자동 복구 미리보기 | ✅ | — | ✅ |
| 순수 Swift, 서드파티 의존성 0, MIT 오픈소스 | ✅ | ✅ (MIT) | 비공개 소스 |

---

## 설치 방법

### 방법 1: 릴리즈 실행 파일 다운로드 (GitHub Releases)

1. [Releases](https://github.com/isnow890/halo/releases) 페이지에서 `halo-vX.Y.Z-arm64.dmg` (또는 `.zip`)를 다운로드합니다.
2. **halo.app**을 `/Applications` 폴더로 드래그합니다.
3. GitHub Releases 배포본은 **ad-hoc 서명(비공증)** 빌드입니다. 최초 실행 전 터미널에서 격리 속성을 한 번 해제해 주세요:
   ```bash
   xattr -cr /Applications/halo.app
   open /Applications/halo.app
   ```

### 방법 2: 소스에서 직접 빌드

macOS 14+ (Apple Silicon) 및 Xcode Command Line Tools(`swift`)가 필요합니다.

```bash
git clone https://github.com/isnow890/halo.git
cd halo

# 로컬 ad-hoc 빌드 (Apple Development 인증서가 있으면 CODESIGN_IDENTITY 생략 가능)
CODESIGN_IDENTITY="-" ./scripts/build-app.sh --install
open /Applications/halo.app
```

배포용 `.dmg` / `.zip` / `SHA256SUMS.txt` 패키징:

```bash
VERSION=0.1.0 ./scripts/package-dmg.sh
```

---

## 권한 설정 및 단축키

메뉴바 슬라이더, 해상도 전환, 가상 HiDPI는 **별도 권한 없이도 바로 동작**합니다. 전역 키보드 밝기 키를 사용하려면 아래 경로에서 `halo`를 허용해 주세요:

- **macOS 14~26**: `시스템 설정 → 개인정보 보호 및 보안 → 손쉬운 사용`
- **macOS 27+**: `시스템 설정 → 개인정보 보호 및 보안 → 기기 제어 및 데이터 접근`

| 단축키 | 동작 |
| :--- | :--- |
| `☀` 밝기 키 · `F14` / `F15` | 대상 디스플레이 밝기 조절 (기본: 마우스 커서 위치 화면) |
| 표준 `F1` / `F2` | 설정의 *표준 F1 / F2로 밝기 조절* 활성화 시 사용 (`fnState=1`이면 자동 활성화) |
| `⌥ + ⇧ + 밝기 키` | 1/64 단위 미세 밝기 조절 |
| `⌃ + ⌥ + ↑ / ↓` | 외장 키보드용 대체 단축키 (설정에서 켜고 끌 수 있음) |

---

## 읽기 전용 진단 CLI

화면 밝기나 해상도를 변경하지 않고 연결된 모니터·DDC/CI 응답·이벤트 탭 권한·HiDPI 목록을 점검할 수 있습니다:

```bash
/Applications/halo.app/Contents/MacOS/halo --diagnose
```

---

## 개인정보, 서명 및 알려진 한계

1. **업데이트 자동 확인 안내 (설정에서 해제 가능)**: *업데이트 자동 확인*이 켜져 있으면 하루 1회 `https://api.github.com/repos/isnow890/halo/releases/latest`에서 최신 버전 태그 번호만 조회합니다. 개인정보나 사용량 텔레메트리는 일절 수집하지 않으며, 설정에서 끌 수 있습니다.
2. **ad-hoc 서명 및 업데이트 후 권한 재허용**: GitHub Releases 사전 빌드 파일은 ad-hoc 서명(`CODESIGN_IDENTITY="-"`)으로 배포됩니다. macOS는 코드 서명 기준으로 권한을 기억하므로 **새 릴리즈로 덮어쓴 뒤에는 개인정보 보호 및 보안에서 기존 `halo` 항목을 `(−)`로 삭제 후 다시 허용**해야 할 수 있습니다. 로컬에서 본인의 Apple Development 인증서로 빌드하면 재빌드 시에도 권한이 유지됩니다.
3. **비공개 macOS API 사용**: `DisplayServices`, `IOAVService`, `CGVirtualDisplay`를 사용합니다. 향후 macOS 업데이트로 심볼이 변경될 수 있으며, `halo`는 동적 로딩으로 미지원 시 안전하게 폴백합니다.
4. **Mac App Store 미지원**: 전역 `CGEventTap` 및 `IOAVService` DDC/CI는 App Sandbox 정책과 양립할 수 없어 GitHub Releases로만 배포합니다.
5. **모니터·어댑터별 DDC 호환성**: DDC/CI 지원 여부는 모니터·허브·케이블 조합마다 다릅니다. DisplayLink 어댑터 경유 모니터는 하드웨어 DDC가 불가능하므로 자동으로 소프트웨어 오버레이/감마 디밍을 사용합니다.
6. **가상 디스플레이 수명**: 가상 HiDPI 화면은 앱 프로세스 수명에 종속됩니다. 정상 종료 시 이전 미러 배치를 복원하지만, 강제 종료(`SIGKILL`) 시에는 시스템 설정에서 배치를 다시 확인해야 할 수 있습니다.

<details>
<summary><strong>문제 해결 / FAQ</strong></summary>

- **"halo이(가) 손상되어 열 수 없습니다" 경고가 뜰 때**: 비공증(ad-hoc) 빌드 격리 속성 때문이며, `xattr -cr /Applications/halo.app`을 한 번 실행하면 정상 실행됩니다.
- **권한을 켰는데도 키보드 밝기 키가 안 먹을 때**: ad-hoc 빌드 교체 후 macOS가 이전 서명 항목을 캐시할 수 있습니다. 설정에서 기존 `halo`를 선택해 `(−)`로 삭제한 뒤 앱을 재시작하고 다시 허용해 주세요.
- **외장 모니터가 소프트웨어 디밍(`SW`)으로만 표시될 때**: 모니터 자체 OSD 메뉴에서 DDC/CI가 켜져 있는지 확인하세요. DisplayLink 독이나 일부 HDMI/USB-C 어댑터는 DDC 신호를 차단합니다. `/Applications/halo.app/Contents/MacOS/halo --diagnose`로 정확한 상태를 확인할 수 있습니다.

</details>

---

## 프로젝트 구조

```text
Sources/
├── CDisplayBridge/        # Objective-C 브릿지 (DisplayServices, IOAVService DDC/CI, CGVirtualDisplay)
└── halo/
    ├── HaloApp.swift      # 순수 AppKit 메뉴바 진입점, 커스텀 템플릿 아이콘 & --diagnose CLI
    ├── Models/            # DisplayItem, DisplayModeItem, VirtualDisplayPreset
    ├── Services/          # DisplayController, DDCChannel, BrightnessKeyMonitor, BrightnessOSDController,
    │                      # SoftwareDimmer, DisplayModeManager, VirtualDisplayManager, DisplayTopology,
    │                      # UpdateChecker
    └── UI/                # SwiftUI MenuBarPopoverView
```

---

## 라이선스

[MIT License](LICENSE)로 배포됩니다.
