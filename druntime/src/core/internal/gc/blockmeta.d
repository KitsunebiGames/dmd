/**
 Functions to manipulate metadata in-block.

 functionality was moved from rt.lifetime
 */
module core.internal.gc.blockmeta;

import core.memory;

alias BlkInfo = GC.BlkInfo;
alias BlkAttr = GC.BlkAttr;

enum : size_t
{
    PAGESIZE = 4096,
    BIGLENGTHMASK = ~(PAGESIZE - 1),
    SMALLPAD = 1,
    MEDPAD = ushort.sizeof,
    LARGEPREFIX = 16, // 16 bytes padding at the front of the array
    LARGEPAD = LARGEPREFIX + 1,
    MAXSMALLSIZE = 256-SMALLPAD,
    MAXMEDSIZE = (PAGESIZE / 2) - MEDPAD
}

// size used to store the TypeInfo at the end of an allocation for structs that have a destructor
size_t structTypeInfoSize(const TypeInfo ti) pure nothrow @nogc
{
    if (ti && typeid(ti) is typeid(TypeInfo_Struct)) // avoid a complete dynamic type cast
    {
        auto sti = cast(TypeInfo_Struct)cast(void*)ti;
        if (sti.xdtor)
            return size_t.sizeof;
    }
    return 0;
}

/**
  Set the allocated length of the array block.  This is called
  any time an array is appended to or its length is set.

  The allocated block looks like this for blocks < PAGESIZE:

  |elem0|elem1|elem2|...|elemN-1|emptyspace|N*elemsize|


  The size of the allocated length at the end depends on the block size:

  a block of 16 to 256 bytes has an 8-bit length.

  a block with 512 to pagesize/2 bytes has a 16-bit length.

  For blocks >= pagesize, the length is a size_t and is at the beginning of the
  block.  The reason we have to do this is because the block can extend into
  more pages, so we cannot trust the block length if it sits at the end of the
  block, because it might have just been extended.  If we can prove in the
  future that the block is unshared, we may be able to change this, but I'm not
  sure it's important.

  In order to do put the length at the front, we have to provide 16 bytes
  buffer space in case the block has to be aligned properly.  In x86, certain
  SSE instructions will only work if the data is 16-byte aligned.  In addition,
  we need the sentinel byte to prevent accidental pointers to the next block.
  Because of the extra overhead, we only do this for page size and above, where
  the overhead is minimal compared to the block size.

  So for those blocks, it looks like:

  |N*elemsize|padding|elem0|elem1|...|elemN-1|emptyspace|sentinelbyte|

  where elem0 starts 16 bytes after the first byte.
  */
bool __setArrayAllocLength(ref BlkInfo info, size_t newlength, bool isshared, const TypeInfo tinext, size_t oldlength = ~0) pure nothrow
{
    size_t typeInfoSize = structTypeInfoSize(tinext);
    return __setArrayAllocLengthImpl(info, newlength, isshared, tinext, oldlength, typeInfoSize);
}

// the impl function, used both above and in core.internal.array.utils
bool __setArrayAllocLengthImpl(ref BlkInfo info, size_t newlength, bool isshared, const TypeInfo tinext, size_t oldlength, size_t typeInfoSize) pure nothrow
{
    import core.atomic;

    if (info.size <= 256)
    {
        import core.checkedint;

        bool overflow;
        auto newlength_padded = addu(newlength,
                                     addu(SMALLPAD, typeInfoSize, overflow),
                                     overflow);

        if (newlength_padded > info.size || overflow)
            // new size does not fit inside block
            return false;

        auto length = cast(ubyte *)(info.base + info.size - typeInfoSize - SMALLPAD);
        if (oldlength != ~0)
        {
            if (isshared)
            {
                return cas(cast(shared)length, cast(ubyte)oldlength, cast(ubyte)newlength);
            }
            else
            {
                if (*length == cast(ubyte)oldlength)
                    *length = cast(ubyte)newlength;
                else
                    return false;
            }
        }
        else
        {
            // setting the initial length, no cas needed
            *length = cast(ubyte)newlength;
        }
        if (typeInfoSize)
        {
            auto typeInfo = cast(TypeInfo*)(info.base + info.size - size_t.sizeof);
            *typeInfo = cast() tinext;
        }
    }
    else if (info.size < PAGESIZE)
    {
        if (newlength + MEDPAD + typeInfoSize > info.size)
            // new size does not fit inside block
            return false;
        auto length = cast(ushort *)(info.base + info.size - typeInfoSize - MEDPAD);
        if (oldlength != ~0)
        {
            if (isshared)
            {
                return cas(cast(shared)length, cast(ushort)oldlength, cast(ushort)newlength);
            }
            else
            {
                if (*length == oldlength)
                    *length = cast(ushort)newlength;
                else
                    return false;
            }
        }
        else
        {
            // setting the initial length, no cas needed
            *length = cast(ushort)newlength;
        }
        if (typeInfoSize)
        {
            auto typeInfo = cast(TypeInfo*)(info.base + info.size - size_t.sizeof);
            *typeInfo = cast() tinext;
        }
    }
    else
    {
        if (newlength + LARGEPAD > info.size)
            // new size does not fit inside block
            return false;
        auto length = cast(size_t *)(info.base);
        if (oldlength != ~0)
        {
            if (isshared)
            {
                return cas(cast(shared)length, cast(size_t)oldlength, cast(size_t)newlength);
            }
            else
            {
                if (*length == oldlength)
                    *length = newlength;
                else
                    return false;
            }
        }
        else
        {
            // setting the initial length, no cas needed
            *length = newlength;
        }
        if (typeInfoSize)
        {
            auto typeInfo = cast(TypeInfo*)(info.base + size_t.sizeof);
            *typeInfo = cast()tinext;
        }
    }
    return true; // resize succeeded
}

/**
  get the allocation size of the array for the given block (without padding or type info)
  */
size_t __arrayAllocLength(ref BlkInfo info, const TypeInfo tinext) pure nothrow
{
    if (info.size <= 256)
        return *cast(ubyte *)(info.base + info.size - structTypeInfoSize(tinext) - SMALLPAD);

    if (info.size < PAGESIZE)
        return *cast(ushort *)(info.base + info.size - structTypeInfoSize(tinext) - MEDPAD);

    return *cast(size_t *)(info.base);
}

/**
  get the padding required to allocate size bytes.  Note that the padding is
  NOT included in the passed in size.  Therefore, do NOT call this function
  with the size of an allocated block.
  */
size_t __arrayPad(size_t size, const TypeInfo tinext) nothrow pure @trusted
{
    return size > MAXMEDSIZE ? LARGEPAD : ((size > MAXSMALLSIZE ? MEDPAD : SMALLPAD) + structTypeInfoSize(tinext));
}
