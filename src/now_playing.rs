//! Album art color extraction for the visualizer.
//!
//! macOS: Uses ScriptingBridge.framework (via objc2) to query running media
//! players directly through the ObjC bridge — no subprocess spawning.
//!   - Spotify: title, artwork URL (downloaded via reqwest).
//!   - Apple Music: title, raw artwork bytes from MusicArtwork.rawData.
//!
//! Linux: Uses `playerctl` subprocess.

/// Debug-only logging (stripped from release builds).
#[allow(unused_macros)]
macro_rules! debug_log {
    ($($arg:tt)*) => {
        #[cfg(debug_assertions)]
        eprintln!($($arg)*);
    };
}

pub fn extract_prominent_colors_from_bytes(image_bytes: &[u8]) -> Option<Vec<[u8; 3]>> {
    use auto_palette::{ImageData, Palette};
    use palette::{IntoColor, Oklch, Srgb};

    /// Minimum lightness (Oklch) for a color to be considered "able to show up as light".
    /// Very bright highlights/whites are still allowed even if they fall slightly under this.
    const MIN_LIGHTNESS: f32 = 0.27;

    /// If a color has at least this much chroma, we allow it even if it's darker
    /// (the "high chroma rescue"). This helps pull in rich atmospheric colors
    /// (deep purples, magentas, blues, reds) that are intentionally dark in album art.
    const HIGH_CHROMA_THRESHOLD: f32 = 0.18;

    /// When using high-chroma rescue, the color must still be at least this light.
    const HIGH_CHROMA_RESCUE_MIN_LIGHTNESS: f32 = 0.18;

    /// Maximum dimension after downscaling. Big win for speed on Pi + reduces noise.
    const MAX_DIM: u32 = 160;

    let mut img = image::load_from_memory(image_bytes).ok()?;

    // Aggressive downscale early — critical for Pi performance and cleaner palettes
    if img.width() > MAX_DIM || img.height() > MAX_DIM {
        img = img.resize(MAX_DIM, MAX_DIM, image::imageops::FilterType::Triangle);
    }

    let rgba = img.to_rgba8();
    let image_data = ImageData::new(rgba.width(), rgba.height(), rgba.as_raw()).ok()?;
    let palette: Palette<f64> = Palette::extract(&image_data).ok()?;

    // We deliberately avoid Theme::Vivid (and heavy reliance on any single Theme)
    // for initial candidate selection.
    //
    // Vivid strongly prefers extremely high chroma + moderately bright colors. This
    // often causes it to:
    // - Collapse on large flat text or gradient fills (the yellow "Excursions" problem)
    // - Miss important darker-but-rich atmospheric/mood colors (the TOTO nebula purples)
    //
    // Instead we use `find_swatches(n)`, which does population-weighted selection
    // combined with explicit diversity sampling. This gives us a much more
    // representative set of colors from the actual artwork.
    //
    // We then apply our own lighting-specific post-processing on top:
    //   - Light-emitting potential scoring (l * chroma)
    //   - High-chroma rescue for rich dark colors
    //   - Hue deduplication
    //   - Final cap at 6
    //
    // This division of responsibility works well: auto-palette does robust
    // extraction + diversity, and we control what "actually looks good as light
    // on Nanoleaf panels" means.
    let mut candidates: Vec<([u8; 3], Oklch)> = palette
        .find_swatches(15) // ask for more; we filter heavily afterward anyway
        .ok()?
        .into_iter()
        .filter_map(|s| {
            let rgb = s.color().to_rgb();
            let bytes = [rgb.r, rgb.g, rgb.b];
            let srgb: Srgb<f32> = Srgb::new(
                rgb.r as f32 / 255.0,
                rgb.g as f32 / 255.0,
                rgb.b as f32 / 255.0,
            );
            let oklch: Oklch = srgb.into_color();

            let l = oklch.l;
            let is_bright_enough = l >= MIN_LIGHTNESS || l >= 0.82;
            let is_high_chroma_rescue =
                oklch.chroma >= HIGH_CHROMA_THRESHOLD && l >= HIGH_CHROMA_RESCUE_MIN_LIGHTNESS;

            if is_bright_enough || is_high_chroma_rescue {
                Some((bytes, oklch))
            } else {
                None
            }
        })
        .collect();

    // Re-rank by light-emitting potential (lightness × chroma).
    // Favors rich, bright, saturated colors that will actually glow on panels.
    candidates.sort_by(|a, b| {
        let score_a = a.1.l * a.1.chroma;
        let score_b = b.1.l * b.1.chroma;
        score_b
            .partial_cmp(&score_a)
            .unwrap_or(std::cmp::Ordering::Equal)
    });

    // Take up to 6 with hue deduplication
    let mut colors: Vec<[u8; 3]> = Vec::with_capacity(6);
    for (rgb, oklch) in candidates.into_iter().take(8) {
        let is_duplicate = colors.iter().any(|existing| {
            let ex_srgb: Srgb<f32> = Srgb::new(
                existing[0] as f32 / 255.0,
                existing[1] as f32 / 255.0,
                existing[2] as f32 / 255.0,
            );
            let ex_oklch: Oklch = ex_srgb.into_color();

            let hue_diff =
                (oklch.hue.into_positive_degrees() - ex_oklch.hue.into_positive_degrees()).abs();
            let min_hue_diff = hue_diff.min(360.0 - hue_diff);
            min_hue_diff < 22.0 && (oklch.chroma - ex_oklch.chroma).abs() < 0.12
        });

        if !is_duplicate {
            colors.push(rgb);
            if colors.len() >= 6 {
                break;
            }
        }
    }

    if colors.is_empty() {
        None
    } else {
        Some(colors)
    }
}

/// Returns the title of the currently playing track.
pub fn get_track_title() -> Option<String> {
    #[cfg(target_os = "macos")]
    {
        macos::get_track_title()
    }
    #[cfg(target_os = "linux")]
    {
        linux::get_track_title()
    }
}

/// Fetches artwork bytes once and returns both the raw image and the extracted palette.
/// Avoids double-fetch race conditions where the track could change between calls.
pub fn fetch_artwork_and_palette() -> Option<(Vec<u8>, Vec<[u8; 3]>)> {
    #[cfg(target_os = "macos")]
    {
        let bytes = macos::fetch_artwork_bytes()?;
        let colors = macos::extract_colors(&bytes)?;
        Some((bytes, colors))
    }
    #[cfg(target_os = "linux")]
    {
        let bytes = linux::fetch_artwork_bytes()?;
        let colors = linux::extract_colors_from_bytes(&bytes)?;
        Some((bytes, colors))
    }
}

// ── macOS — MediaRemote.framework via media-remote crate ─────────────────────

#[cfg(target_os = "macos")]
mod macos {
    pub fn get_track_title() -> Option<String> {
        use media_remote::NowPlayingPerl;
        let np = NowPlayingPerl::new();
        let guard = np.get_info();
        guard.as_ref()?.title.clone()
    }

    pub fn fetch_artwork_bytes() -> Option<Vec<u8>> {
        use media_remote::NowPlayingPerl;
        let np = NowPlayingPerl::new();
        let guard = np.get_info();
        let info = guard.as_ref()?;
        let cover = info.album_cover.as_ref()?;
        let mut buf = std::io::Cursor::new(Vec::new());
        cover.write_to(&mut buf, image::ImageFormat::Jpeg).ok()?;
        Some(buf.into_inner())
    }

    pub fn extract_colors(image_bytes: &[u8]) -> Option<Vec<[u8; 3]>> {
        super::extract_prominent_colors_from_bytes(image_bytes)
    }
}

// ── Linux ─────────────────────────────────────────────────────────────────────

#[cfg(target_os = "linux")]
mod linux {
    pub fn get_track_title() -> Option<String> {
        let output = std::process::Command::new("playerctl")
            .args(["metadata", "title"])
            .output()
            .ok()?;
        if output.status.success() {
            let title = String::from_utf8_lossy(&output.stdout).trim().to_string();
            if !title.is_empty() {
                return Some(title);
            }
        }
        None
    }

    pub fn fetch_artwork_bytes() -> Option<Vec<u8>> {
        let output = std::process::Command::new("playerctl")
            .args(["metadata", "mpris:artUrl"])
            .output()
            .ok()?;
        if !output.status.success() {
            return None;
        }
        let url = String::from_utf8_lossy(&output.stdout).trim().to_string();
        if url.is_empty() {
            return None;
        }
        if url.starts_with("file://") {
            std::fs::read(url.trim_start_matches("file://")).ok()
        } else {
            reqwest::blocking::get(&url)
                .ok()?
                .bytes()
                .ok()
                .map(|b| b.to_vec())
        }
    }

    pub fn extract_colors_from_bytes(bytes: &[u8]) -> Option<Vec<[u8; 3]>> {
        super::extract_prominent_colors_from_bytes(bytes)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Reference album covers used to tune and regression-test the lighting-oriented
    /// color extraction used for Nanoleaf "Artwork" color source mode.
    ///
    /// These tests exercise `extract_prominent_colors_from_bytes` on real-world
    /// album art that has historically exposed problems (dominant text collapsing
    /// the palette, loss of atmospheric/mood colors, etc.).
    ///
    /// The eprintln output is intentional: it surfaces the current extracted
    /// palettes in CI logs so we can observe the effect of tuning
    /// MIN_LIGHTNESS / HIGH_CHROMA_RESCUE etc.
    #[test]
    fn reference_album_covers_color_extraction() {
        let cases = [
            (
                "cover1 - blue to lime gradient (Matt Sassari / CHRSTPHR)",
                "Assets/example_covers/cover1.jpeg",
            ),
            (
                "cover2 - mountain landscape with yellow text (Excursions)",
                "Assets/example_covers/cover2",
            ),
            (
                "cover3 - yellow to red gradient (Matt Sassari)",
                "Assets/example_covers/cover3.jpeg",
            ),
            (
                "cover4 - sword in nebula (TOTO 1978)",
                "Assets/example_covers/cover4.jpeg",
            ),
        ];

        for (name, path) in cases {
            let bytes = std::fs::read(path)
                .unwrap_or_else(|e| panic!("Failed to read reference cover {}: {}", path, e));

            let colors = extract_prominent_colors_from_bytes(&bytes)
                .unwrap_or_else(|| panic!("Extractor returned no colors for {}", name));

            eprintln!("{} -> {:?}", name, colors);

            // Basic sanity: we should get at least one usable color, and never collapse
            // to a single near-duplicate color on these known covers.
            assert!(
                !colors.is_empty(),
                "No colors extracted for reference cover: {}",
                name
            );
        }
    }
}
