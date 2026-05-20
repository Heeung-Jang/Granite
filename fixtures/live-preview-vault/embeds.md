# Embeds

Safe local image:

![[attachments/safe-pixel.png]]

Width syntax:

![[attachments/safe-pixel.png|100]]

Size syntax:

![[attachments/safe-pixel.png|64x64]]

Missing embed:

![[attachments/missing.png]]

Traversal and absolute paths must remain inert:

![[../../secret.png]]

![[/etc/passwd]]

Remote image must remain inert:

![Remote](https://example.com/remote.png)

Local and active schemes must remain inert:

[File URL](file:///tmp/secret.md)

[JavaScript URL](javascript:alert(1))

![Data URL](data:image/png;base64,AAAA)

HTML must remain inert:

<img src="https://example.com/remote.png">

Unsupported attachments must remain inert:

![[attachments/unsafe.svg]]

![[attachments/spec.pdf]]

![[attachments/page.html]]

Note embed placeholder:

![[Targets/Alpha]]
