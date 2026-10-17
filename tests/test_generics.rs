#![allow(clippy::needless_late_init, clippy::uninlined_format_args)]

use core::fmt::{self, Debug, Display};
use core::str::FromStr;
use thiserror::Error;

pub struct NoFormat;

#[derive(Debug)]
pub struct DebugOnly;

pub struct DisplayOnly;

impl Display for DisplayOnly {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        f.write_str("display only")
    }
}

#[derive(Debug)]
pub struct DebugAndDisplay;

impl Display for DebugAndDisplay {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        f.write_str("debug and display")
    }
}

// Should expand to:
//
//     impl<E> Display for EnumDebugField<E>
//     where
//         E: Debug;
//
//     impl<E> Error for EnumDebugField<E>
//     where
//         Self: Debug + Display;
//
#[derive(Error, Debug)]
pub enum EnumDebugGeneric<E> {
    #[error("{0:?}")]
    FatalError(E),
}

// Should expand to:
//
//     impl<E> Display for EnumFromGeneric<E>;
//
//     impl<E> Error for EnumFromGeneric<E>
//     where
//         EnumDebugGeneric<E>: Error + 'static,
//         Self: Debug + Display;
//
#[derive(Error, Debug)]
pub enum EnumFromGeneric<E> {
    #[error("enum from generic")]
    Source(#[from] EnumDebugGeneric<E>),
}

// Should expand to:
//
//     impl<HasDisplay, HasDebug, HasNeither> Display
//         for EnumCompound<HasDisplay, HasDebug, HasNeither>
//     where
//         HasDisplay: Display,
//         HasDebug: Debug;
//
//     impl<HasDisplay, HasDebug, HasNeither> Error
//         for EnumCompound<HasDisplay, HasDebug, HasNeither>
//     where
//         Self: Debug + Display;
//
#[derive(Error)]
pub enum EnumCompound<HasDisplay, HasDebug, HasNeither> {
    #[error("{0} {1:?}")]
    DisplayDebug(HasDisplay, HasDebug),
    #[error("{0}")]
    Display(HasDisplay, HasNeither),
    #[error("{1:?}")]
    Debug(HasNeither, HasDebug),
}

impl<HasDisplay, HasDebug, HasNeither> Debug for EnumCompound<HasDisplay, HasDebug, HasNeither> {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        f.write_str("EnumCompound")
    }
}

#[test]
fn test_display_enum_compound() {
    let mut instance: EnumCompound<DisplayOnly, DebugOnly, NoFormat>;

    instance = EnumCompound::DisplayDebug(DisplayOnly, DebugOnly);
    assert_eq!(format!("{}", instance), "display only DebugOnly");

    instance = EnumCompound::Display(DisplayOnly, NoFormat);
    assert_eq!(format!("{}", instance), "display only");

    instance = EnumCompound::Debug(NoFormat, DebugOnly);
    assert_eq!(format!("{}", instance), "DebugOnly");
}

// Should expand to:
//
//     impl<E> Display for EnumTransparentGeneric<E>
//     where
//         E: Display;
//
//     impl<E> Error for EnumTransparentGeneric<E>
//     where
//         E: Error,
//         Self: Debug + Display;
//
#[derive(Error, Debug)]
pub enum EnumTransparentGeneric<E> {
    #[error(transparent)]
    Other(E),
}

// Should expand to:
//
//     impl<E> Display for StructDebugGeneric<E>
//     where
//         E: Debug;
//
//     impl<E> Error for StructDebugGeneric<E>
//     where
//         Self: Debug + Display;
//
#[derive(Error, Debug)]
#[error("{underlying:?}")]
pub struct StructDebugGeneric<E> {
    pub underlying: E,
}

// Should expand to:
//
//     impl<E> Error for StructFromGeneric<E>
//     where
//         StructDebugGeneric<E>: Error + 'static,
//         Self: Debug + Display;
//
#[derive(Error, Debug)]
pub struct StructFromGeneric<E> {
    #[from]
    pub source: StructDebugGeneric<E>,
}

// Should expand to:
//
//     impl<E> Display for StructTransparentGeneric<E>
//     where
//         E: Display;
//
//     impl<E> Error for StructTransparentGeneric<E>
//     where
//         E: Error,
//         Self: Debug + Display;
//
#[derive(Error, Debug)]
#[error(transparent)]
pub struct StructTransparentGeneric<E>(pub E);

// Should expand to:
//
//     impl<T: FromStr> Display for AssociatedTypeError<T>
//     where
//         T::Err: Display;
//
//     impl<T: FromStr> Error for AssociatedTypeError<T>
//     where
//         Self: Debug + Display;
//
#[derive(Error, Debug)]
pub enum AssociatedTypeError<T: FromStr> {
    #[error("couldn't parse matrix")]
    Other,
    #[error("couldn't parse entry: {0}")]
    EntryParseError(T::Err),
}

// Regression test for https://github.com/dtolnay/thiserror/issues/345
#[test]
fn test_no_bound_on_named_fmt() {
    #[derive(Error, Debug)]
    #[error("{thing}", thing = "...")]
    struct Error<T> {
        thing: T,
    }

    let error = Error { thing: DebugOnly };
    assert_eq!(error.to_string(), "...");
}

#[test]
fn test_multiple_bound() {
    #[derive(Error, Debug)]
    #[error("0x{thing:x} 0x{thing:X}")]
    pub struct Error<T> {
        thing: T,
    }

    let error = Error { thing: 0xFFi32 };
    assert_eq!(error.to_string(), "0xff 0xFF");
}

// Regression test for https://github.com/dtolnay/thiserror/issues/317.
#[test]
fn test_recursive_generic_source() {
    #[derive(Error, Debug)]
    enum RecursiveError<T> {
        #[error("recurse")]
        Recurse(#[source] Box<RecursiveError<T>>),
        #[error("payload")]
        Payload(T),
    }

    fn as_error<E: std::error::Error>(error: &E) -> &dyn std::error::Error {
        error
    }

    assert_eq!(
        as_error(&RecursiveError::Payload("hello")).to_string(),
        "payload"
    );
}

#[test]
fn test_recursive_generic_struct_source() {
    #[derive(Error, Debug)]
    #[error("recursive")]
    struct RecursiveError<T> {
        #[source]
        source: Box<RecursiveError<T>>,
        payload: T,
    }

    fn assert_error<E: std::error::Error>() {}

    assert_error::<RecursiveError<&'static str>>();
}

#[test]
fn test_nonrecursive_generic_source() {
    #[derive(Error, Debug)]
    #[error("generic source")]
    struct GenericSource<T> {
        #[source]
        source: T,
    }

    let error = GenericSource {
        source: std::io::Error::other("source"),
    };
    let _: &dyn std::error::Error = &error;
}

#[test]
fn test_recursive_generic_optional_source() {
    #[derive(Error, Debug)]
    #[error("recursive")]
    struct RecursiveError<T> {
        #[source]
        source: Option<Box<RecursiveError<T>>>,
        payload: T,
    }

    let error = RecursiveError {
        source: Some(Box::new(RecursiveError {
            source: None,
            payload: 1,
        })),
        payload: 2,
    };
    assert_eq!(
        std::error::Error::source(&error).unwrap().to_string(),
        "recursive"
    );
}

#[test]
fn test_foreign_generic_source_with_same_ident() {
    mod foreign {
        #[derive(thiserror::Error, Debug)]
        #[error(transparent)]
        pub struct RecursiveError<T>(pub T);
    }

    #[derive(Error, Debug)]
    #[error("outer")]
    struct RecursiveError<T> {
        #[source]
        source: foreign::RecursiveError<T>,
    }

    let error = RecursiveError {
        source: foreign::RecursiveError(std::io::Error::other("foreign")),
    };
    assert_eq!(
        std::error::Error::source(&error).unwrap().to_string(),
        "foreign"
    );
}

#[test]
fn test_recursive_source_with_nonstatic_parameter() {
    #[derive(Error, Debug)]
    #[error("recursive")]
    struct RecursiveError<T> {
        #[source]
        source: Option<Box<RecursiveError<T>>>,
        marker: std::marker::PhantomData<fn(T)>,
    }

    fn check<'a>(_: &'a str) {
        let error = RecursiveError::<&'a str> {
            source: None,
            marker: std::marker::PhantomData,
        };
        assert!(std::error::Error::source(&error).is_none());
    }

    check(&String::from("borrowed"));
}
