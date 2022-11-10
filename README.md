# APScript (WIP)

An interpreter for the AP© Computer Science Principles pseudocode language
written in [Zig](https://ziglang.org/).

> Warning: Heavily WIP as this is only on GitHub for me to work on while at
> school.

## Examples

### Printing to the console

```sql
age <- 23
DISPLAY("You are", age, "years old.")
```


```bash
You are 23 years old.
```

### Mutating variables

```sql
age <- 0

REPEAT UNTIL (age > 105) {
  age <- age + 1
  DISPLAY("You are", age, "years old.")
}

DISPLAY("RIP")
```

```bash
You are 1 years old.
You are 2 years old.
You are 3 years old.
You are 4 years old.
...
You are 102 years old.
You are 103 years old.
You are 104 years old.
You are 105 years old.
RIP
```

### Accessing input from the console

> Note: The interpreter always tries to coerce results from `INPUT` into numbers first.
> If that fails, then it returns a string.

```sql
age <- INPUT("What is your age?")
DISPLAY("You are ", age, "years old.")
```

```bash
What is your age? 23 [Enter]
You are 23 years old.
```

## License

[MIT](./LICENSE)
