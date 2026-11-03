//! Plan B prototype: a GPUI window with two terminal panes, each attached to an
//! ADE holder socket. The holder owns the PTY; we keep a client-side vt100
//! parser fed by Snapshot + Output frames and paint its grid.
//!
//! Usage: proto-b <ADE_HOME> <session-id-1> <session-id-2>
//! Test hooks (env):
//!   PROTO_B_DUMP_DIR=dir      every 300ms write each pane's screen text to dir/<id>.txt
//!   PROTO_B_RESIZE=ms:WxH[,ms:WxH...]  resize the window after ms milliseconds

mod keys;

use octomux_proto::{Frame, Hello, Kind, Role};
use gpui::{
    App, Bounds, Context, Element, ElementId, Entity, FocusHandle, Focusable, FontWeight,
    GlobalElementId, Hsla, InspectorElementId, KeyDownEvent, LayoutId, Pixels, ShapedLine,
    SharedString, Size, Style, TextAlign, TextRun, UnderlineStyle, Window, WindowBounds,
    WindowOptions, div, point, prelude::*, px, rgb, size,
};
use std::io::Write;
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::time::Duration;

const FONT_FAMILY: &str = "Menlo";
const FONT_SIZE: f32 = 13.;
const PAD: f32 = 6.;
const DEFAULT_FG: u32 = 0xd8d8d8;
const DEFAULT_BG: u32 = 0x1c1c1e;

// ---------------------------------------------------------------- pane model

struct Conn {
    writer: UnixStream,
    _reader: gpui::Task<()>,
}

pub struct Pane {
    id: String,
    socket: PathBuf,
    parser: vt100::Parser,
    cols: u16,
    rows: u16,
    conn: Option<Conn>,
    tried: bool,
    status: String,
    focus: FocusHandle,
}

impl Pane {
    fn new(home: &str, id: String, cx: &mut Context<Self>) -> Self {
        Pane {
            socket: PathBuf::from(home).join("run").join(format!("{id}.sock")),
            id,
            parser: vt100::Parser::new(24, 80, 0),
            cols: 0,
            rows: 0,
            conn: None,
            tried: false,
            status: "connecting".into(),
            focus: cx.focus_handle(),
        }
    }

    /// Called from layout with the grid size that fits; connects on first call,
    /// sends Resize afterwards when it changes.
    fn fit(&mut self, cols: u16, rows: u16, cx: &mut Context<Self>) {
        let changed = cols != self.cols || rows != self.rows;
        if changed {
            self.cols = cols;
            self.rows = rows;
            self.parser.screen_mut().set_size(rows, cols);
        }
        match &mut self.conn {
            Some(conn) if changed => {
                let _ = Frame::resize(cols, rows).write_to(&mut conn.writer);
            }
            Some(_) => {}
            None if !self.tried => {
                self.tried = true;
                self.connect(cx);
            }
            None => {}
        }
    }

    fn connect(&mut self, cx: &mut Context<Self>) {
        let mut stream = match UnixStream::connect(&self.socket) {
            Ok(s) => s,
            Err(e) => {
                self.status = format!("connect failed: {e}");
                return;
            }
        };
        let hello = Hello { version: 1, role: Role::Attach, cols: self.cols, rows: self.rows };
        if let Err(e) = Frame::json(Kind::Hello, &hello).write_to(&mut stream) {
            self.status = format!("hello failed: {e}");
            return;
        }
        let mut reader = stream.try_clone().expect("clone socket");
        let (tx, rx) = async_channel::unbounded::<Frame>();
        std::thread::spawn(move || {
            while let Ok(Some(frame)) = Frame::read_from(&mut reader) {
                if tx.send_blocking(frame).is_err() {
                    break;
                }
            }
        });
        let task = cx.spawn(async move |this, cx| {
            while let Ok(first) = rx.recv().await {
                // Drain whatever else is queued so a burst costs one repaint.
                let mut batch = vec![first];
                while let Ok(f) = rx.try_recv() {
                    batch.push(f);
                }
                let alive = this.update(cx, |pane, cx| {
                    for f in batch {
                        pane.on_frame(f);
                    }
                    cx.notify();
                });
                if alive.is_err() {
                    return;
                }
            }
            let _ = this.update(cx, |pane, cx| {
                pane.status = "disconnected".into();
                cx.notify();
            });
        });
        self.status = "attached".into();
        self.conn = Some(Conn { writer: stream, _reader: task });
    }

    fn on_frame(&mut self, f: Frame) {
        match f.kind {
            Kind::Snapshot => {
                let (rows, cols) = self.parser.screen().size();
                self.parser = vt100::Parser::new(rows, cols, 0);
                self.parser.process(&f.payload);
            }
            Kind::Output => self.parser.process(&f.payload),
            Kind::Exited => self.status = format!("exited {}", String::from_utf8_lossy(&f.payload)),
            _ => {}
        }
    }

    fn send(&mut self, bytes: Vec<u8>) {
        if let Some(conn) = &mut self.conn {
            let _ = conn.writer.write_all(&Frame::new(Kind::Input, bytes).encode());
        }
    }

    fn key_down(&mut self, ev: &KeyDownEvent, window: &mut Window, cx: &mut Context<Self>) {
        let app_cursor = self.parser.screen().application_cursor();
        if let Some(bytes) = keys::encode(&ev.keystroke, app_cursor) {
            self.send(bytes);
            window.prevent_default();
            cx.stop_propagation();
        }
    }
}

impl Focusable for Pane {
    fn focus_handle(&self, _: &App) -> FocusHandle {
        self.focus.clone()
    }
}

impl Render for Pane {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let focused = self.focus.is_focused(window);
        let header = format!(
            "{}  {}x{}  {}{}",
            &self.id[..self.id.len().min(8)],
            self.cols,
            self.rows,
            self.status,
            if self.parser.screen().alternate_screen() { "  [alt]" } else { "" }
        );
        div()
            .flex()
            .flex_col()
            .flex_1()
            .h_full()
            .min_w(px(0.))
            .track_focus(&self.focus)
            .on_key_down(cx.listener(Self::key_down))
            .on_mouse_down(
                gpui::MouseButton::Left,
                cx.listener(|this, _, window, cx| {
                    this.focus.focus(window, cx);
                    cx.notify();
                }),
            )
            .child(
                div()
                    .h(px(22.))
                    .px(px(8.))
                    .flex()
                    .items_center()
                    .text_size(px(11.))
                    .text_color(if focused { rgb(0xffffff) } else { rgb(0x8a8a8a) })
                    .bg(if focused { rgb(0x3a3a50) } else { rgb(0x2a2a2c) })
                    .child(header),
            )
            .child(div().flex_1().min_h(px(0.)).child(Grid { pane: cx.entity(), focused }))
    }
}

// ---------------------------------------------------------------- grid element

struct Grid {
    pane: Entity<Pane>,
    focused: bool,
}

struct Painted {
    rects: Vec<(Bounds<Pixels>, Hsla)>,
    lines: Vec<(gpui::Point<Pixels>, ShapedLine)>,
    cursor: Option<Bounds<Pixels>>,
    line_height: Pixels,
}

#[derive(Clone, Copy, PartialEq)]
struct Pen {
    fg: Hsla,
    bold: bool,
    italic: bool,
    underline: bool,
}

impl IntoElement for Grid {
    type Element = Self;
    fn into_element(self) -> Self {
        self
    }
}

impl Element for Grid {
    type RequestLayoutState = ();
    type PrepaintState = Painted;
    fn id(&self) -> Option<ElementId> {
        None
    }
    fn source_location(&self) -> Option<&'static std::panic::Location<'static>> {
        None
    }
    fn request_layout(
        &mut self,
        _: Option<&GlobalElementId>,
        _: Option<&InspectorElementId>,
        window: &mut Window,
        cx: &mut App,
    ) -> (LayoutId, ()) {
        let mut style = Style::default();
        style.size.width = gpui::relative(1.).into();
        style.size.height = gpui::relative(1.).into();
        (window.request_layout(style, [], cx), ())
    }

    fn prepaint(
        &mut self,
        _: Option<&GlobalElementId>,
        _: Option<&InspectorElementId>,
        bounds: Bounds<Pixels>,
        _: &mut (),
        window: &mut Window,
        cx: &mut App,
    ) -> Painted {
        let font_size = px(FONT_SIZE);
        let base = gpui::font(FONT_FAMILY);
        let ts = window.text_system().clone();
        let fid = ts.resolve_font(&base);
        let cw = ts.advance(fid, font_size, 'm').map_or(px(7.8), |s| s.width);
        let lh = (font_size * 1.25).round();
        let origin = point(bounds.left() + px(PAD), bounds.top() + px(PAD / 2.));
        let cols = (((bounds.size.width - px(PAD * 2.)) / cw).floor() as u16).max(2);
        let rows = (((bounds.size.height - px(PAD)) / lh).floor() as u16).max(1);
        self.pane.update(cx, |p, cx| p.fit(cols, rows, cx));

        let cell = size(cw, lh);
        let mut out = Painted { rects: vec![], lines: vec![], cursor: None, line_height: lh };
        let pane = self.pane.read(cx);
        let screen = pane.parser.screen();
        let (srows, scols) = screen.size();
        for r in 0..srows.min(rows) {
            let y = origin.y + lh * r as f32;
            // (col, text, pen, bg, wide)
            let mut cells: Vec<(u16, String, Pen, Option<Hsla>, bool)> = Vec::new();
            for c in 0..scols.min(cols) {
                let Some(cell) = screen.cell(r, c) else { continue };
                if cell.is_wide_continuation() {
                    continue;
                }
                let mut fg = color(cell.fgcolor(), true);
                let mut bg = match cell.bgcolor() {
                    vt100::Color::Default => None,
                    other => Some(color(other, false)),
                };
                if cell.inverse() {
                    let b = bg.unwrap_or(rgb(DEFAULT_BG).into());
                    bg = Some(fg);
                    fg = b;
                }
                if cell.dim() {
                    fg.a *= 0.6;
                }
                let text = if cell.has_contents() { cell.contents().to_string() } else { " ".to_string() };
                let pen = Pen { fg, bold: cell.bold(), italic: cell.italic(), underline: cell.underline() };
                cells.push((c, text, pen, bg, cell.is_wide()));
            }
            // Backgrounds: merge equal neighbours.
            let mut span: Option<(u16, u16, Hsla)> = None;
            for (c, _, _, bg, wide) in &cells {
                let w = if *wide { 2 } else { 1 };
                match (span, bg) {
                    (Some((s, e, f)), Some(b)) if e == *c && f == *b => span = Some((s, e + w, f)),
                    _ => {
                        if let Some((s, e, f)) = span.take() {
                            out.rects.push((cell_rect(origin, cell, r, s, e), f));
                        }
                        span = bg.map(|b| (*c, c + w, b));
                    }
                }
            }
            if let Some((s, e, f)) = span {
                out.rects.push((cell_rect(origin, cell, r, s, e), f));
            }
            // Text: one shaped run per same-pen stretch; wide glyphs on their own.
            let mut i = 0;
            while i < cells.len() {
                let (c0, _, pen, _, wide0) = &cells[i];
                let mut text = String::new();
                let mut j = i;
                if *wide0 {
                    text.push_str(&cells[i].1);
                    j += 1;
                } else {
                    while j < cells.len()
                        && cells[j].2 == *pen
                        && !cells[j].4
                        && cells[j].0 == c0 + (j - i) as u16
                    {
                        text.push_str(&cells[j].1);
                        j += 1;
                    }
                }
                if !text.trim().is_empty() {
                    let mut font = base.clone();
                    if pen.bold {
                        font.weight = FontWeight::BOLD;
                    }
                    if pen.italic {
                        font.style = gpui::FontStyle::Italic;
                    }
                    let run = TextRun {
                        len: text.len(),
                        font,
                        color: pen.fg,
                        background_color: None,
                        underline: pen.underline.then_some(UnderlineStyle { thickness: px(1.), color: Some(pen.fg), wavy: false }),
                        strikethrough: None,
                    };
                    let force = if *wide0 { cw * 2. } else { cw };
                    let shaped = ts.shape_line(SharedString::from(text), font_size, &[run], Some(force));
                    out.lines.push((point(origin.x + cw * *c0 as f32, y), shaped));
                }
                i = j;
            }
        }
        if !screen.hide_cursor() {
            let (cr, cc) = screen.cursor_position();
            if cr < rows && cc < cols {
                out.cursor = Some(Bounds::new(
                    point(origin.x + cw * cc as f32, origin.y + lh * cr as f32),
                    cell,
                ));
            }
        }
        out
    }

    fn paint(
        &mut self,
        _: Option<&GlobalElementId>,
        _: Option<&InspectorElementId>,
        bounds: Bounds<Pixels>,
        _: &mut (),
        p: &mut Painted,
        window: &mut Window,
        cx: &mut App,
    ) {
        window.with_content_mask(Some(gpui::ContentMask { bounds }), |window| {
            window.paint_quad(gpui::fill(bounds, rgb(DEFAULT_BG)));
            for (r, f) in &p.rects {
                window.paint_quad(gpui::fill(*r, *f));
            }
            for (o, line) in &p.lines {
                let _ = line.paint(*o, p.line_height, TextAlign::Left, None, window, cx);
            }
            if let Some(c) = p.cursor {
                if self.focused {
                    let mut f: Hsla = rgb(0x7aa2f7).into();
                    f.a = 0.6;
                    window.paint_quad(gpui::fill(c, f));
                } else {
                    window.paint_quad(gpui::outline(c, rgb(0x7aa2f7), gpui::BorderStyle::Solid));
                }
            }
        });
    }
}

fn cell_rect(origin: gpui::Point<Pixels>, cell: Size<Pixels>, row: u16, c0: u16, c1: u16) -> Bounds<Pixels> {
    Bounds::new(
        point(origin.x + cell.width * c0 as f32, origin.y + cell.height * row as f32),
        size(cell.width * (c1 - c0) as f32, cell.height),
    )
}

/// xterm-ish palette: 16 ANSI, 6x6x6 cube, 24 greys; truecolor passes through.
fn color(c: vt100::Color, fg: bool) -> Hsla {
    const ANSI: [u32; 16] = [
        0x1c1c1e, 0xe06c75, 0x98c379, 0xe5c07b, 0x61afef, 0xc678dd, 0x56b6c2, 0xd8d8d8,
        0x5c6370, 0xff7b86, 0xb5e890, 0xffd68a, 0x82c4ff, 0xdf9cf3, 0x7fd6e0, 0xffffff,
    ];
    let hex = match c {
        vt100::Color::Default => if fg { DEFAULT_FG } else { DEFAULT_BG },
        vt100::Color::Idx(i) if i < 16 => ANSI[i as usize],
        vt100::Color::Idx(i) if i < 232 => {
            let i = i - 16;
            let lvl = |v: u8| if v == 0 { 0 } else { 55 + 40 * v as u32 };
            (lvl(i / 36) << 16) | (lvl((i / 6) % 6) << 8) | lvl(i % 6)
        }
        vt100::Color::Idx(i) => {
            let g = 8 + 10 * (i as u32 - 232);
            (g << 16) | (g << 8) | g
        }
        vt100::Color::Rgb(r, g, b) => ((r as u32) << 16) | ((g as u32) << 8) | b as u32,
    };
    rgb(hex).into()
}

// ---------------------------------------------------------------- root view

struct Root {
    panes: Vec<Entity<Pane>>,
}

impl Render for Root {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        div()
            .size_full()
            .flex()
            .flex_row()
            .gap(px(2.))
            .bg(rgb(0x000000))
            .font_family(FONT_FAMILY)
            .children(self.panes.iter().cloned())
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 3 {
        eprintln!("usage: proto-b <ADE_HOME> <session-id> [<session-id>]");
        std::process::exit(2);
    }
    let home = args[1].clone();
    let ids: Vec<String> = args[2..].to_vec();
    let platform = gpui_platform::current_platform(false);
    gpui::Application::with_platform(platform).run(move |cx: &mut App| {
        let bounds = Bounds::centered(None, size(px(1200.), px(700.)), cx);
        let window = cx
            .open_window(
                WindowOptions {
                    window_bounds: Some(WindowBounds::Windowed(bounds)),
                    titlebar: Some(gpui::TitlebarOptions {
                        title: Some("ADE proto-b".into()),
                        ..Default::default()
                    }),
                    ..Default::default()
                },
                |window, cx| {
                    let panes: Vec<Entity<Pane>> =
                        ids.iter().map(|id| cx.new(|cx| Pane::new(&home, id.clone(), cx))).collect();
                    if let Some(first) = panes.first() {
                        first.read(cx).focus.clone().focus(window, cx);
                    }
                    cx.new(|_| Root { panes })
                },
            )
            .expect("open window");
        cx.on_window_closed(|cx, _| {
            if cx.windows().is_empty() {
                cx.quit();
            }
        })
        .detach();
        cx.activate(true);
        install_test_hooks(window, cx);
    });
}

#[cfg(feature = "selfshot")]
fn selfshot(window: &mut Window, target: &str) {
    match window.render_to_image() {
        Ok(img) => {
            if let Err(e) = img.save(target) {
                eprintln!("selfshot save failed: {e}");
            }
        }
        Err(e) => eprintln!("selfshot render failed: {e}"),
    }
}
#[cfg(not(feature = "selfshot"))]
fn selfshot(_: &mut Window, target: &str) {
    eprintln!("selfshot not compiled in (build with --features selfshot); skipped {target}");
}

fn install_test_hooks(window: gpui::WindowHandle<Root>, cx: &mut App) {
    if let Ok(dir) = std::env::var("PROTO_B_DUMP_DIR") {
        let dir = PathBuf::from(dir);
        let _ = std::fs::create_dir_all(&dir);
        cx.spawn(async move |cx| loop {
            cx.background_executor().timer(Duration::from_millis(300)).await;
            let ok = window.update(cx, |root, window, cx| {
                for p in &root.panes {
                    let p = p.read(cx);
                    let _ = std::fs::write(dir.join(format!("{}.txt", p.id)), p.parser.screen().contents());
                }
                // verify.sh writes a target path to `shot-request`; we render the
                // last frame offscreen and save it there.
                let req = dir.join("shot-request");
                if let Ok(target) = std::fs::read_to_string(&req) {
                    let _ = std::fs::remove_file(&req);
                    selfshot(window, target.trim());
                }
            });
            if ok.is_err() {
                break;
            }
        })
        .detach();
    }
    // Keystrokes dispatched through GPUI's normal key path (focus -> on_key_down
    // -> encoder -> Input frame), e.g. "1500:e c h o space ç ğ enter ctrl-c".
    if let Ok(spec) = std::env::var("PROTO_B_TYPE") {
        if let Some((ms, keys)) = spec.split_once(':') {
            let ms: u64 = ms.parse().unwrap_or(1000);
            let keys: Vec<String> = keys.split_whitespace().map(str::to_string).collect();
            cx.spawn(async move |cx| {
                cx.background_executor().timer(Duration::from_millis(ms)).await;
                for k in keys {
                    let any: gpui::AnyWindowHandle = window.into();
                    let _ = cx.update_window(any, |_, window, cx| {
                        if let Ok(ks) = gpui::Keystroke::parse(&k) {
                            window.dispatch_keystroke(ks, cx);
                        }
                    });
                    cx.background_executor().timer(Duration::from_millis(20)).await;
                }
            })
            .detach();
        }
    }
    if let Ok(spec) = std::env::var("PROTO_B_RESIZE") {
        for item in spec.split(',') {
            let Some((ms, wh)) = item.split_once(':') else { continue };
            let Some((w, h)) = wh.split_once('x') else { continue };
            let (Ok(ms), Ok(w), Ok(h)) = (ms.parse::<u64>(), w.parse::<f32>(), h.parse::<f32>()) else { continue };
            cx.spawn(async move |cx| {
                cx.background_executor().timer(Duration::from_millis(ms)).await;
                let _ = window.update(cx, |_, window, _| window.resize(size(px(w), px(h))));
            })
            .detach();
        }
    }
}
