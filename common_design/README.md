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
- `action.soft` 必须搭配 `action.onSoft`，不能搭配 `action.primary`。
- `border.subtle` 仅用于装饰分隔；需要识别的控件使用 `border.control`。
- 半透明颜色需要先按实际背景合成，不能直接进行对比度计算。
