# Nested Marker Hierarchy

<!-- case: unordered-3-level -->
Unordered:

- Parent unordered
  - Child unordered
    - Grandchild unordered
- Second parent unordered

<!-- case: ordered-3-level -->
Ordered:

1. Parent ordered
   1. Child ordered
      1. Grandchild ordered
2. Second parent ordered

<!-- case: ordered-width-normalization -->
Ordered width normalization:

1. One digit ordered
9. One digit sibling
10. Two digit sibling
100. Three digit sibling

<!-- case: task-3-level -->
Tasks:

- [ ] Parent task
  - [ ] Child task
    - [X] Grandchild task
- [x] Second parent task

<!-- case: mixed-bullet-ordered-task -->
Mixed bullet ordered task:

- Parent bullet
  1. Ordered child
     - [ ] Task grandchild
  - Bullet child

<!-- case: mixed-task-bullet-ordered -->
Mixed task bullet ordered:

- [ ] Parent task
  - Bullet child
    1. Ordered grandchild

<!-- case: tab-space-normalization -->
Tab and space normalization:

- Parent tab case
	- Tab child
  - Space child
    - Space grandchild

<!-- case: cluster-break -->
Cluster break:

- Parent before break
  - Child before break

Paragraph break.

- Parent after break

<!-- case: active-reveal-targets -->
Active reveal targets:

- Active parent target
  - Active child target
    - Active grandchild target

<!-- case: wrapped-list-item -->
Wrapped item:

- Parent with a long line that should wrap when the editor is narrow enough, keeping the marker on the first visual line and continuation text aligned to the list head indent rather than the marker slot.

<!-- case: hr-table-regression-near-list -->
Horizontal rule and table regression:

---

| Name | Status |
| --- | --- |
| Alpha | Draft |

<!-- case: code-fence-negative -->
Code fence negative:

```markdown
- Not a rendered list
  - Not a rendered child
---
| Not | Table |
```
