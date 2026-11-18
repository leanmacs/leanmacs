//! The disk image: `Leanmacs-<build-id>.dmg`, whose volume holds the app,
//! a link to `/Applications` to drag it onto, the licence and a README.
//!
//! Everything here is pure or runs through the [`Process`] port:
//!
//! - [`file_name`] and [`build_of`]: the image's name, and the build it names.
//! - [`plan`]: the programs that stage the volume's root and pack it with
//!   `hdiutil`, in order, after refusing a layout that could delete or pack
//!   the wrong thing.
//! - [`pack`]: reads the app's `CFBundleVersion`, refuses an app built for
//!   another build, and runs the plan. `leanmacs-release dmg` calls it.
//! - [`check_volume`]: compares a mounted volume's root with [`ENTRIES`].
//!   Names that start with `.` are left out of the comparison, since
//!   `hdiutil` may add `.fseventsd` and the like, which Finder hides.
//!   `editor-release-std`'s `tests/dmg_mount.rs` (`mise run dmg-check`)
//!   mounts a built image and runs it.

use std::error::Error;
use std::fmt;
use std::path::{Component, Path, PathBuf};

use crate::build_id::BuildId;
use crate::ports::{Invocation, Process, RunError, text};

/// The app's name in the volume, and the only name [`plan`] takes for it.
pub const APP: &str = "Leanmacs.app";
/// The volume's name, which Finder shows.
pub const VOLUME: &str = "Leanmacs";
/// The README's name in the volume.
pub const README: &str = "README.txt";
/// The licence's name in the volume.
pub const LICENSE: &str = "LICENSE";
/// The link to drag the app onto.
pub const APPLICATIONS: &str = "Applications";
/// Where [`APPLICATIONS`] points.
pub const APPLICATIONS_TARGET: &str = "/Applications";

/// What kind of thing a name in the volume is.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    /// A directory (the app bundle is one).
    Directory,
    /// A regular file.
    File,
    /// A symbolic link, not followed.
    Symlink,
    /// Anything else: a socket, a device, a pipe.
    Other,
}

impl fmt::Display for Kind {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::Directory => "a directory",
            Self::File => "a file",
            Self::Symlink => "a symbolic link",
            Self::Other => "neither a file, a directory nor a link",
        })
    }
}

/// One name the volume's root must hold.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Entry {
    /// Its name.
    pub name: &'static str,
    /// What it must be.
    pub kind: Kind,
    /// Where it must point, for a link.
    pub target: Option<&'static str>,
}

/// The volume's root, in the order [`plan`] stages it: the app, the link to
/// `/Applications`, the licence and the README, and nothing else.
pub const ENTRIES: [Entry; 4] = [
    Entry {
        name: APP,
        kind: Kind::Directory,
        target: None,
    },
    Entry {
        name: APPLICATIONS,
        kind: Kind::Symlink,
        target: Some(APPLICATIONS_TARGET),
    },
    Entry {
        name: LICENSE,
        kind: Kind::File,
        target: None,
    },
    Entry {
        name: README,
        kind: Kind::File,
        target: None,
    },
];

/// The image's file name for the build `id`: `Leanmacs-<id>.dmg`.
#[must_use]
pub fn file_name(id: &BuildId) -> String {
    format!("{VOLUME}-{id}.dmg")
}

/// The build a file name made by [`file_name`] names, or `None` for any
/// other name.
#[must_use]
pub fn build_of(file_name: &str) -> Option<BuildId> {
    let id = file_name
        .strip_prefix(VOLUME)?
        .strip_prefix('-')?
        .strip_suffix(".dmg")?;
    BuildId::parse(id).ok()
}

/// What [`plan`] packs.
#[derive(Debug, Clone, Copy)]
pub struct Inputs<'a> {
    /// The built app bundle, named [`APP`].
    pub app: &'a Path,
    /// The licence file.
    pub license: &'a Path,
    /// The README file.
    pub readme: &'a Path,
}

/// Why [`plan`] refuses a layout.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PlanError {
    /// A path is not absolute.
    Relative(PathBuf),
    /// A path holds a `..`, so where it lies cannot be told from its text.
    NotNormal(PathBuf),
    /// The staging directory, which is removed before and after, equals,
    /// holds or lies inside the output directory or the app.
    Overlap {
        /// The staging directory.
        staging: PathBuf,
        /// The output directory or the app.
        other: PathBuf,
    },
    /// The app's file name is not [`APP`].
    AppName(PathBuf),
}

impl fmt::Display for PlanError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Relative(path) => write!(f, "{} is not an absolute path", path.display()),
            Self::NotNormal(path) => write!(f, "{} holds `..`", path.display()),
            Self::Overlap { staging, other } => write!(
                f,
                "the staging directory {} overlaps {}: it is removed before and after packing",
                staging.display(),
                other.display()
            ),
            Self::AppName(path) => write!(f, "{} is not named {APP}", path.display()),
        }
    }
}

impl Error for PlanError {}

/// Whether one of `a` and `b` is the other or lies inside it, by their
/// components.
fn overlaps(a: &Path, b: &Path) -> bool {
    a.starts_with(b) || b.starts_with(a)
}

/// The programs that pack `inputs` into `<out>/Leanmacs-<id>.dmg`, in
/// order: clear `staging`, make it and `out`, copy the app with `ditto`
/// (which keeps its signature, links and extended attributes), copy the
/// licence and the README, link `/Applications`, pack the folder with
/// `hdiutil create` as a compressed (`UDZO`) HFS+ image, replacing an image
/// of the same name, and clear `staging` again.
///
/// # Errors
///
/// A path that is not absolute or holds `..`; a staging directory that
/// equals, holds or lies inside `out` or the app, which the first and last
/// steps would delete; an app not named [`APP`].
pub fn plan(
    inputs: &Inputs<'_>,
    staging: &Path,
    out: &Path,
    id: &BuildId,
) -> Result<Vec<Invocation>, PlanError> {
    for path in [inputs.app, inputs.license, inputs.readme, staging, out] {
        if !path.is_absolute() {
            return Err(PlanError::Relative(path.to_owned()));
        }
        if path.components().any(|c| c == Component::ParentDir) {
            return Err(PlanError::NotNormal(path.to_owned()));
        }
    }
    for other in [out, inputs.app] {
        if overlaps(staging, other) {
            return Err(PlanError::Overlap {
                staging: staging.to_owned(),
                other: other.to_owned(),
            });
        }
    }
    if inputs.app.file_name().and_then(|n| n.to_str()) != Some(APP) {
        return Err(PlanError::AppName(inputs.app.to_owned()));
    }
    let clear = Invocation::new("rm").arg("-rf").arg(staging);
    Ok(vec![
        clear.clone(),
        Invocation::new("mkdir").arg("-p").arg(staging).arg(out),
        Invocation::new("ditto")
            .arg(inputs.app)
            .arg(staging.join(APP)),
        Invocation::new("cp")
            .arg(inputs.license)
            .arg(staging.join(LICENSE)),
        Invocation::new("cp")
            .arg(inputs.readme)
            .arg(staging.join(README)),
        Invocation::new("ln")
            .arg("-s")
            .arg(APPLICATIONS_TARGET)
            .arg(staging.join(APPLICATIONS)),
        Invocation::new("hdiutil")
            .args(["create", "-volname", VOLUME, "-srcfolder"])
            .arg(staging)
            .args(["-fs", "HFS+", "-format", "UDZO", "-ov"])
            .arg(out.join(file_name(id))),
        clear,
    ])
}

/// `plutil` printing the app's `CFBundleVersion`, which `editorApp` writes
/// as the build ID.
#[must_use]
pub fn bundle_version(app: &Path) -> Invocation {
    Invocation::new("plutil")
        .args(["-extract", "CFBundleVersion", "raw", "-o", "-"])
        .arg(app.join("Contents").join("Info.plist"))
        .captured()
}

/// Why [`pack`] did not make the image.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PackError {
    /// The layout is refused.
    Plan(PlanError),
    /// A program failed: reading the app's version, or a step of the plan.
    Run {
        /// Its command line.
        command: String,
        /// How it failed.
        source: RunError,
    },
    /// The app's `CFBundleVersion` is not a build ID.
    NotABuild {
        /// The app.
        app: PathBuf,
        /// What `plutil` printed, trimmed.
        value: String,
    },
    /// The app was built for another build than this one.
    Stale {
        /// The app.
        app: PathBuf,
        /// The build it was built for.
        built: BuildId,
        /// This build.
        expected: BuildId,
    },
}

impl fmt::Display for PackError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Plan(error) => error.fmt(f),
            Self::Run { command, source } => write!(f, "`{command}` failed: {source}"),
            Self::NotABuild { app, value } => write!(
                f,
                "{}'s CFBundleVersion is `{value}`, not a build ID: run `mise run app`",
                app.display()
            ),
            Self::Stale {
                app,
                built,
                expected,
            } => write!(
                f,
                "{} was built for build {built}, this build is {expected}: run `mise run app`",
                app.display()
            ),
        }
    }
}

impl Error for PackError {
    fn source(&self) -> Option<&(dyn Error + 'static)> {
        match self {
            Self::Plan(error) => Some(error),
            Self::Run { source, .. } => Some(source),
            Self::NotABuild { .. } | Self::Stale { .. } => None,
        }
    }
}

/// Packs `inputs` into `<out>/Leanmacs-<expected>.dmg` and returns the
/// image's path. The layout is checked first ([`plan`]), then the app's
/// `CFBundleVersion` is read ([`bundle_version`]) and must be `expected`,
/// so a stale bundle is never shipped under a new build's name; only then
/// does the plan run, stopping at the first program that fails.
///
/// # Errors
///
/// As [`PackError`] says.
pub fn pack(
    process: &mut impl Process,
    inputs: &Inputs<'_>,
    staging: &Path,
    out: &Path,
    expected: &BuildId,
) -> Result<PathBuf, PackError> {
    let steps = plan(inputs, staging, out, expected).map_err(PackError::Plan)?;
    let run_error = |invocation: &Invocation| {
        let command = invocation.to_string();
        move |source| PackError::Run { command, source }
    };
    let read = bundle_version(inputs.app);
    let value = text(process, &read).map_err(run_error(&read))?;
    let value = value.trim();
    let built = BuildId::parse(value).map_err(|_| PackError::NotABuild {
        app: inputs.app.to_owned(),
        value: value.to_owned(),
    })?;
    if &built != expected {
        return Err(PackError::Stale {
            app: inputs.app.to_owned(),
            built,
            expected: expected.clone(),
        });
    }
    for step in &steps {
        process.run(step).map_err(run_error(step))?;
    }
    Ok(out.join(file_name(expected)))
}

/// One name found in a mounted volume's root.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Found {
    /// Its name.
    pub name: String,
    /// What it is, not following a link.
    pub kind: Kind,
    /// Where it points, for a link.
    pub target: Option<PathBuf>,
}

/// One way a volume's root differs from [`ENTRIES`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Problem {
    /// A name of [`ENTRIES`] is not there.
    Missing(&'static str),
    /// A name not in [`ENTRIES`] is there.
    Extra(String),
    /// A name is there as another kind.
    WrongKind {
        /// The name.
        name: &'static str,
        /// What it must be.
        expected: Kind,
        /// What it is.
        found: Kind,
    },
    /// A link points elsewhere.
    WrongTarget {
        /// The name.
        name: &'static str,
        /// Where it must point.
        expected: &'static str,
        /// Where it points.
        found: Option<PathBuf>,
    },
}

impl fmt::Display for Problem {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Missing(name) => write!(f, "{name} is missing"),
            Self::Extra(name) => write!(f, "{name} should not be there"),
            Self::WrongKind {
                name,
                expected,
                found,
            } => write!(f, "{name} is {found}, not {expected}"),
            Self::WrongTarget {
                name,
                expected,
                found,
            } => match found {
                Some(found) => {
                    write!(f, "{name} points to {}, not {expected}", found.display())
                }
                None => write!(f, "{name} points nowhere, not to {expected}"),
            },
        }
    }
}

/// Every way `listing`, a mounted volume's root, differs from [`ENTRIES`]:
/// each missing name, each extra one, each of the wrong kind and each link
/// that points elsewhere, in [`ENTRIES`]' order and then the listing's.
/// Names that start with `.` are ignored.
#[must_use]
pub fn check_volume(listing: &[Found]) -> Vec<Problem> {
    let listing: Vec<&Found> = listing
        .iter()
        .filter(|f| !f.name.starts_with('.'))
        .collect();
    let mut problems = Vec::new();
    for entry in &ENTRIES {
        let Some(found) = listing.iter().find(|f| f.name == entry.name) else {
            problems.push(Problem::Missing(entry.name));
            continue;
        };
        if found.kind != entry.kind {
            problems.push(Problem::WrongKind {
                name: entry.name,
                expected: entry.kind,
                found: found.kind,
            });
        } else if let Some(expected) = entry.target
            && found.target.as_deref() != Some(Path::new(expected))
        {
            problems.push(Problem::WrongTarget {
                name: entry.name,
                expected,
                found: found.target.clone(),
            });
        }
    }
    for found in listing {
        if !ENTRIES.iter().any(|e| e.name == found.name) {
            problems.push(Problem::Extra(found.name.clone()));
        }
    }
    problems
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fake::RecordingProcess;

    fn id() -> BuildId {
        BuildId::parse("20010203040506").expect("an ID")
    }

    #[test]
    fn the_file_name_round_trips() {
        assert_eq!(file_name(&id()), "Leanmacs-20010203040506.dmg");
        assert_eq!(build_of(&file_name(&id())), Some(id()));
        for other in [
            "Leanmacs-20010203040506.img",
            "Leanmacs20010203040506.dmg",
            "Other-20010203040506.dmg",
            "Leanmacs-2001.dmg",
            "Leanmacs-20011303040506.dmg",
        ] {
            assert_eq!(build_of(other), None, "{other}");
        }
    }

    fn inputs() -> Inputs<'static> {
        Inputs {
            app: Path::new("/w/lean/.lake/build/Leanmacs.app"),
            license: Path::new("/w/LICENSE"),
            readme: Path::new("/w/packaging/macos/README.txt"),
        }
    }

    #[test]
    fn the_plan_stages_the_four_entries_and_packs_them() {
        let steps = plan(
            &inputs(),
            Path::new("/w/target/dmg/staging"),
            Path::new("/w/dist"),
            &id(),
        )
        .expect("a plan");
        let lines: Vec<String> = steps.iter().map(ToString::to_string).collect();
        assert_eq!(
            lines,
            [
                "rm -rf /w/target/dmg/staging",
                "mkdir -p /w/target/dmg/staging /w/dist",
                "ditto /w/lean/.lake/build/Leanmacs.app /w/target/dmg/staging/Leanmacs.app",
                "cp /w/LICENSE /w/target/dmg/staging/LICENSE",
                "cp /w/packaging/macos/README.txt /w/target/dmg/staging/README.txt",
                "ln -s /Applications /w/target/dmg/staging/Applications",
                "hdiutil create -volname Leanmacs -srcfolder /w/target/dmg/staging -fs HFS+ -format UDZO -ov /w/dist/Leanmacs-20010203040506.dmg",
                "rm -rf /w/target/dmg/staging",
            ]
        );
        assert!(steps.iter().all(|s| !s.captured));
    }

    #[test]
    fn the_plan_refuses_a_relative_path_or_one_with_dot_dot() {
        let staging = Path::new("/w/target/dmg/staging");
        let out = Path::new("/w/dist");
        assert_eq!(
            plan(&inputs(), staging, Path::new("dist"), &id()),
            Err(PlanError::Relative("dist".into()))
        );
        assert_eq!(
            plan(
                &Inputs {
                    app: Path::new("lean/.lake/build/Leanmacs.app"),
                    ..inputs()
                },
                staging,
                out,
                &id()
            ),
            Err(PlanError::Relative("lean/.lake/build/Leanmacs.app".into()))
        );
        assert_eq!(
            plan(
                &Inputs {
                    license: Path::new("LICENSE"),
                    ..inputs()
                },
                staging,
                out,
                &id()
            ),
            Err(PlanError::Relative("LICENSE".into()))
        );
        assert_eq!(
            plan(&inputs(), Path::new("staging"), out, &id()),
            Err(PlanError::Relative("staging".into()))
        );
        assert_eq!(
            plan(&inputs(), Path::new("/w/dist/../staging"), out, &id()),
            Err(PlanError::NotNormal("/w/dist/../staging".into()))
        );
    }

    #[test]
    fn the_plan_refuses_a_staging_directory_that_overlaps_the_output_or_the_app() {
        let app = inputs().app;
        for (staging, out, other) in [
            ("/w/dist", "/w/dist", "/w/dist"),
            ("/w", "/w/dist", "/w/dist"),
            ("/w/dist/staging", "/w/dist", "/w/dist"),
            (
                "/w/lean/.lake/build/Leanmacs.app",
                "/w/dist",
                app.to_str().unwrap_or(""),
            ),
            ("/w/lean", "/w/dist", app.to_str().unwrap_or("")),
            (
                "/w/lean/.lake/build/Leanmacs.app/Contents",
                "/w/dist",
                app.to_str().unwrap_or(""),
            ),
        ] {
            assert_eq!(
                plan(&inputs(), Path::new(staging), Path::new(out), &id()),
                Err(PlanError::Overlap {
                    staging: staging.into(),
                    other: other.into()
                }),
                "{staging} {out}"
            );
        }
        // A sibling whose name begins with the other's is no overlap.
        assert!(
            plan(
                &inputs(),
                Path::new("/w/dist-staging"),
                Path::new("/w/dist"),
                &id()
            )
            .is_ok()
        );
    }

    #[test]
    fn the_plan_refuses_an_app_not_named_leanmacs_app() {
        assert_eq!(
            plan(
                &Inputs {
                    app: Path::new("/w/Other.app"),
                    ..inputs()
                },
                Path::new("/w/staging"),
                Path::new("/w/dist"),
                &id()
            ),
            Err(PlanError::AppName("/w/Other.app".into()))
        );
    }

    fn version_is(
        version: &'static str,
    ) -> RecordingProcess<impl FnMut(&Invocation) -> Result<Vec<u8>, RunError>> {
        RecordingProcess::new(move |i: &Invocation| {
            Ok(if i.program == "plutil" {
                version.into()
            } else {
                Vec::new()
            })
        })
    }

    #[test]
    fn pack_reads_the_app_s_build_then_runs_the_plan() {
        let mut process = version_is("20010203040506\n");
        let (staging, out) = (Path::new("/w/staging"), Path::new("/w/dist"));
        let made = pack(&mut process, &inputs(), staging, out, &id()).expect("packed");
        assert_eq!(made, Path::new("/w/dist/Leanmacs-20010203040506.dmg"));
        let mut expected = vec![bundle_version(inputs().app)];
        expected.extend(plan(&inputs(), staging, out, &id()).expect("a plan"));
        assert_eq!(process.runs, expected);
        assert_eq!(
            process.runs[0].to_string(),
            "plutil -extract CFBundleVersion raw -o - /w/lean/.lake/build/Leanmacs.app/Contents/Info.plist"
        );
    }

    #[test]
    fn pack_refuses_an_app_built_for_another_build_and_runs_no_step() {
        let mut process = version_is("20010203040507\n");
        let error = pack(
            &mut process,
            &inputs(),
            Path::new("/w/staging"),
            Path::new("/w/dist"),
            &id(),
        )
        .expect_err("stale");
        assert_eq!(
            error.to_string(),
            "/w/lean/.lake/build/Leanmacs.app was built for build 20010203040507, this build is 20010203040506: run `mise run app`"
        );
        assert_eq!(process.runs.len(), 1);
    }

    #[test]
    fn pack_refuses_an_app_whose_version_is_no_build_id() {
        let mut process = version_is("0.1.0\n");
        let error = pack(
            &mut process,
            &inputs(),
            Path::new("/w/staging"),
            Path::new("/w/dist"),
            &id(),
        )
        .expect_err("not a build");
        assert_eq!(
            error,
            PackError::NotABuild {
                app: inputs().app.to_owned(),
                value: "0.1.0".into()
            }
        );
        assert_eq!(process.runs.len(), 1);
    }

    #[test]
    fn pack_refuses_a_bad_layout_before_running_anything() {
        let mut process = version_is("20010203040506\n");
        let error = pack(
            &mut process,
            &inputs(),
            Path::new("staging"),
            Path::new("/w/dist"),
            &id(),
        )
        .expect_err("relative");
        assert_eq!(
            error,
            PackError::Plan(PlanError::Relative("staging".into()))
        );
        assert!(process.runs.is_empty());
    }

    #[test]
    fn pack_stops_at_the_first_step_that_fails() {
        let mut process = RecordingProcess::new(|i: &Invocation| {
            if i.program == "plutil" {
                Ok(b"20010203040506".to_vec())
            } else if i.program == "ditto" {
                Err(RunError::Failed(Some(1)))
            } else {
                Ok(Vec::new())
            }
        });
        let error = pack(
            &mut process,
            &inputs(),
            Path::new("/w/staging"),
            Path::new("/w/dist"),
            &id(),
        )
        .expect_err("ditto fails");
        assert!(
            matches!(&error, PackError::Run { command, source: RunError::Failed(Some(1)) } if command.starts_with("ditto ")),
            "{error:?}"
        );
        assert_eq!(
            process.runs.last().map(|i| i.program.clone()),
            Some("ditto".into())
        );
    }

    fn found(name: &str, kind: Kind, target: Option<&str>) -> Found {
        Found {
            name: name.into(),
            kind,
            target: target.map(PathBuf::from),
        }
    }

    fn exact() -> Vec<Found> {
        vec![
            found(README, Kind::File, None),
            found(APPLICATIONS, Kind::Symlink, Some("/Applications")),
            found(APP, Kind::Directory, None),
            found(LICENSE, Kind::File, None),
            found(".fseventsd", Kind::Directory, None),
        ]
    }

    fn with(name: &str, replacement: Option<Found>) -> Vec<Found> {
        let mut listing: Vec<Found> = exact().into_iter().filter(|f| f.name != name).collect();
        listing.extend(replacement);
        listing
    }

    #[test]
    fn check_volume_accepts_the_exact_list_in_any_order_and_ignores_dot_names() {
        assert_eq!(check_volume(&exact()), []);
    }

    #[test]
    fn check_volume_reports_a_missing_readme() {
        assert_eq!(
            check_volume(&with(README, None)),
            [Problem::Missing(README)]
        );
    }

    #[test]
    fn check_volume_reports_an_extra_file() {
        let mut listing = exact();
        listing.push(found("notes.txt", Kind::File, None));
        assert_eq!(check_volume(&listing), [Problem::Extra("notes.txt".into())]);
    }

    #[test]
    fn check_volume_reports_applications_as_a_directory() {
        assert_eq!(
            check_volume(&with(
                APPLICATIONS,
                Some(found(APPLICATIONS, Kind::Directory, None))
            )),
            [Problem::WrongKind {
                name: APPLICATIONS,
                expected: Kind::Symlink,
                found: Kind::Directory
            }]
        );
    }

    #[test]
    fn check_volume_reports_applications_linking_elsewhere() {
        let problems = check_volume(&with(
            APPLICATIONS,
            Some(found(
                APPLICATIONS,
                Kind::Symlink,
                Some("/Users/ada/Applications"),
            )),
        ));
        assert_eq!(
            problems,
            [Problem::WrongTarget {
                name: APPLICATIONS,
                expected: "/Applications",
                found: Some("/Users/ada/Applications".into())
            }]
        );
        assert_eq!(
            problems[0].to_string(),
            "Applications points to /Users/ada/Applications, not /Applications"
        );
    }

    #[test]
    fn check_volume_reports_license_as_a_directory() {
        let problems = check_volume(&with(LICENSE, Some(found(LICENSE, Kind::Directory, None))));
        assert_eq!(
            problems,
            [Problem::WrongKind {
                name: LICENSE,
                expected: Kind::File,
                found: Kind::Directory
            }]
        );
        assert_eq!(
            problems[0].to_string(),
            "LICENSE is a directory, not a file"
        );
    }

    #[test]
    fn check_volume_reports_every_problem_at_once() {
        assert_eq!(
            check_volume(&[found("x", Kind::Other, None)]),
            [
                Problem::Missing(APP),
                Problem::Missing(APPLICATIONS),
                Problem::Missing(LICENSE),
                Problem::Missing(README),
                Problem::Extra("x".into()),
            ]
        );
    }
}
