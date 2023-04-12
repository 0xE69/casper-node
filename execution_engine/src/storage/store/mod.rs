mod store_ext;
#[cfg(test)]
pub(crate) mod tests;

use std::borrow::Cow;

use casper_types::bytesrepr::{self, Bytes, FromBytes, ToBytes};

pub use self::store_ext::StoreExt;
use crate::storage::transaction_source::{Readable, Writable};

/// Store is responsible for abstracting `get` and `put` operations over the underlying store
/// specified by its associated `Handle` type.
pub trait Store<K, V> {
    /// Errors possible from this store.
    type Error: From<bytesrepr::Error>;

    /// Underlying store type.
    type Handle;

    /// `handle` returns the underlying store.
    fn handle(&self) -> Self::Handle;

    /// Returns an optional value (may exist or not) as read through a transaction, or an error
    /// of the associated `Self::Error` variety.
    fn get<T>(&self, txn: &T, key: &K) -> Result<Option<V>, Self::Error>
    where
        T: Readable<Handle = Self::Handle>,
        K: ToBytes,
        V: FromBytes,
        Self::Error: From<T::Error>,
    {
        let handle = self.handle();
        match txn.read(handle, &key.to_bytes()?)? {
            None => Ok(None),
            Some(value_bytes) => {
                let value = bytesrepr::deserialize(value_bytes.into())?;
                Ok(Some(value))
            }
        }
    }

    /// Returns an optional value (may exist or not) as read through a transaction, or an error
    /// of the associated `Self::Error` variety.
    fn get_raw<T>(&self, txn: &T, key: &K) -> Result<Option<Bytes>, Self::Error>
    where
        T: Readable<Handle = Self::Handle>,
        K: AsRef<[u8]>,
        Self::Error: From<T::Error>,
    {
        let handle = self.handle();
        Ok(txn.read(handle, key.as_ref())?)
    }

    /// Puts a `value` into the store at `key` within a transaction, potentially returning an
    /// error of type `Self::Error` if that fails.
    fn put<T>(&self, txn: &mut T, key: &K, value: &V) -> Result<(), Self::Error>
    where
        T: Writable<Handle = Self::Handle>,
        K: ToBytes,
        V: ToBytes,
        Self::Error: From<T::Error>,
    {
        let key_bytes = key.to_bytes()?;
        let value_bytes = value.to_bytes()?;
        let handle = self.handle();
        txn.write(handle, &key_bytes, &value_bytes)
            .map_err(Into::into)
    }

    /// Puts a raw `value` into the store at `key` within a transaction, potentially returning an
    /// error of type `Self::Error` if that fails.
    ///
    /// This accepts a [`Cow`] object as a value to allow different implementations to choose if
    /// they want to use owned value (i.e. put it in a cache without cloning) or the raw bytes
    /// (write it into a persistent store).
    fn put_raw<T>(
        &self,
        txn: &mut T,
        key: &K,
        value_bytes: Cow<'_, [u8]>,
    ) -> Result<(), Self::Error>
    where
        T: Writable<Handle = Self::Handle>,
        K: AsRef<[u8]>,
        Self::Error: From<T::Error>,
    {
        let handle = self.handle();
        txn.write(handle, key.as_ref(), &value_bytes)
            .map_err(Into::into)
    }
}
