# LightNote 앱 아이콘

명호쌤 파비콘을 캐릭터 참고 이미지로 사용해 연필을 든 모습으로 제작했습니다. 내장 image_gen 도구를 사용했으며 배경은 투명합니다.

- `Resources/AppIcon.png`: 생성 원본 PNG
- `Resources/AppIcon.icns`: macOS용 다중 해상도 아이콘
- `scripts/make-icon.sh`: 16~1024px 아이콘을 묶는 재생성 스크립트

ICNS는 Xcode Resources와 터미널 빌드 모두에 포함되며 Info.plist의 CFBundleIconFile로 연결됩니다.

## 제작 프롬프트

```text
Create one polished macOS app icon illustration for LightNote using the supplied image as the character identity reference. Preserve the recognizable friendly Korean male teacher avatar: black rounded bowl cut bangs, round thin metal glasses, warm skin, smiling face, soft high-quality 3D emoji-like rendering. Change the fist pose into a natural hand firmly holding one clearly visible oversized yellow wooden pencil with graphite tip pointing diagonally up beside his face; readable at small icon sizes. Head and hand only, compact centered silhouette, generous 9% safe padding, clean professional app-icon composition, transparent background outside the avatar. No lettering, no words, no watermark, no app-icon placeholder grid, no border or rounded square background. Square 1024x1024 composition. Keep the original teacher's hairstyle, glasses, face and friendly expression, with pencil being the main new element.
```

생성된 원본은 1254×1254px이며 macOS의 표준 아이콘 크기로 리사이즈하여 패키징했습니다. 구성과 형태 편집은 이미지 생성 도구에서 수행하고 크기 변환은 macOS sips/iconutil을 사용했습니다.
