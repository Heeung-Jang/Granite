# Fenced Code Blocks

```yaml
title: Granite
enabled: true
count: 3
# comment
message: "안녕하세요"
```

```yml
status: active
```

```java
public class Example {
    public static void main(String[] args) {
        // comment
        String value = "Granite";
        int count = 42;
    }
}
```

```swift
struct Example {
    let value = "Granite"
    // comment
}
```

```rust
fn main() {
    let value = "Granite";
    // comment
}
```

```rs
pub fn answer() -> i32 {
    42
}
```

```json
{
  "name": "Granite",
  "enabled": true,
  "count": 3
}
```

```bash
if [ -n "$HOME" ]; then
  echo "Granite"
fi
```

```sh
# comment
export NAME="Granite"
```

```sql
select id, name from notes where id = 42;
-- comment
```

```unknown-language-with-a-very-long-label-that-should-be-clamped
plain text
```

```
plain text without info
```

~~~yaml
tilde: true
~~~

# Boundary Fixture

```text
first block
```

## Between fenced blocks

````
body line
``` not a closer because trailing content exists
``` not a closer because trailing content exists
```
still inside four-backtick block
````

Normal paragraph after the four-backtick block.

```text
second block
~~~
tilde line should not close a backtick block
```

## Next heading after fenced blocks

```
third block
```

Final paragraph outside fenced code.

```rust
unclosed_body();
