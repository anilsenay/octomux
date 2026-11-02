//! Keystroke -> bytes for the PTY (xterm conventions).
use gpui::Keystroke;

pub fn encode(k: &Keystroke, app_cursor: bool) -> Option<Vec<u8>> {
    let m = &k.modifiers;
    if m.platform {
        return None; // Cmd-* stays with the app
    }
    let key = k.key.as_str();
    let modcode = 1 + m.shift as u8 + 2 * m.alt as u8 + 4 * m.control as u8;
    let csi = |fin: char| -> Option<Vec<u8>> {
        Some(if modcode > 1 {
            format!("\x1b[1;{modcode}{fin}")
        } else if app_cursor {
            format!("\x1bO{fin}")
        } else {
            format!("\x1b[{fin}")
        }
        .into_bytes())
    };
    let tilde = |n: u8| -> Option<Vec<u8>> {
        Some(if modcode > 1 { format!("\x1b[{n};{modcode}~") } else { format!("\x1b[{n}~") }.into_bytes())
    };
    let esc_if_alt = |b: &[u8]| -> Option<Vec<u8>> {
        let mut v = Vec::with_capacity(b.len() + 1);
        if m.alt {
            v.push(0x1b);
        }
        v.extend_from_slice(b);
        Some(v)
    };
    match key {
        "up" => return csi('A'),
        "down" => return csi('B'),
        "right" => return csi('C'),
        "left" => return csi('D'),
        "home" => return csi('H'),
        "end" => return csi('F'),
        "delete" => return tilde(3),
        "pageup" => return tilde(5),
        "pagedown" => return tilde(6),
        "enter" => return esc_if_alt(b"\r"),
        "escape" => return esc_if_alt(b"\x1b"),
        "tab" if m.shift => return Some(b"\x1b[Z".to_vec()),
        "tab" => return esc_if_alt(b"\t"),
        "backspace" => return esc_if_alt(if m.control { b"\x08" } else { b"\x7f" }),
        "space" if m.control => return Some(vec![0]),
        _ => {}
    }
    if m.control {
        let mut it = key.chars();
        let ch = it.next()?;
        if it.next().is_some() {
            return None;
        }
        let b = match ch.to_ascii_lowercase() {
            c @ 'a'..='z' => c as u8 - b'a' + 1,
            '@' | '2' => 0,
            '[' | '3' => 0x1b,
            '\\' | '4' => 0x1c,
            ']' | '5' => 0x1d,
            '^' | '6' => 0x1e,
            '_' | '-' | '/' | '7' => 0x1f,
            _ => return None,
        };
        return esc_if_alt(&[b]);
    }
    // Printable text: prefer what the layout produced (ç, ğ, ı, ö, ş, ü, Option-chars).
    let text = k.key_char.clone().or_else(|| (key == "space").then(|| " ".to_string()))?;
    if text.is_empty() {
        return None;
    }
    Some(text.into_bytes())
}

#[cfg(test)]
mod tests {
    use super::*;
    fn ks(s: &str, ch: Option<&str>) -> Keystroke {
        let mut k = Keystroke::parse(s).unwrap();
        k.key_char = ch.map(str::to_string);
        k
    }
    #[test]
    fn encodes() {
        assert_eq!(encode(&ks("a", Some("a")), false).unwrap(), b"a");
        assert_eq!(encode(&ks("ctrl-c", None), false).unwrap(), b"\x03");
        assert_eq!(encode(&ks("enter", None), false).unwrap(), b"\r");
        assert_eq!(encode(&ks("backspace", None), false).unwrap(), b"\x7f");
        assert_eq!(encode(&ks("up", None), false).unwrap(), b"\x1b[A");
        assert_eq!(encode(&ks("up", None), true).unwrap(), b"\x1bOA");
        assert_eq!(encode(&ks("escape", None), false).unwrap(), b"\x1b");
        assert_eq!(encode(&ks("tab", None), false).unwrap(), b"\t");
        assert_eq!(encode(&ks("ç", Some("ç")), false).unwrap(), "ç".as_bytes());
        assert_eq!(encode(&ks("ı", Some("ı")), false).unwrap(), "ı".as_bytes());
        assert_eq!(encode(&ks("shift-ğ", Some("Ğ")), false).unwrap(), "Ğ".as_bytes());
        assert_eq!(encode(&ks("space", None), false).unwrap(), b" ");
        assert!(encode(&ks("cmd-c", None), false).is_none());
    }
}
