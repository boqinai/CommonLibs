# common_design

Boqinai Flutter 应用共用的语义色套件。包内提供经过对比度评审的浅色、深色色板，以及 WCAG 对比度检查工具。

```dart
final colors = CommonColors.resolve(brightness);
final primary = colors.action.primary;
final card = colors.surface.card;
```

应用可以覆盖状态色，但应保留语义角色：

```dart
final appColors = CommonColors.light.copyWith(
  status: CommonColors.light.status.copyWith(
    success: const Color(0xFF0A6B48),
  ),
);
```

## 边界

- 包含品牌、操作、表面、文字、边界、状态和遮罩语义色。
- 不包含收入/支出、分类、彩票球等业务色。
- `brand.base` 仅用于品牌填充或 Logo，其上内容使用 `brand.onBase`。深色表面的品牌文字和图标使用 `action.primary`，不要直接使用 `brand.base`。
- `action.soft` 必须搭配 `action.onSoft`，不能搭配 `action.primary`。需要依靠容器边界识别控件或状态时，必须搭配 `border.control`，特别是在浅色 `backgroundSubtle` 和深色 `raised` 上。
- `border.subtle` 仅用于装饰分隔；需要识别的控件使用 `border.control`。深色 `raised` 上需要可辨识分隔时也使用 `border.control`。
- `text.disabled` 仅用于不可用组件，不用于占位符或普通说明文字。
- `overlay.shadow` 已包含透明度，可直接作为阴影色使用。
- 半透明颜色需要先按实际背景合成，不能直接进行对比度计算。
