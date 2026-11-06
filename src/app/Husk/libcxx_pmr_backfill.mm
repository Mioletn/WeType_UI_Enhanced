/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * iOS 12.2 backfill: std::pmr arrived in libc++ with iOS 13.
 *
 * FEXCore unconditionally derives from std::pmr::memory_resource
 * (fextl::pmr::default_resource, named_monotonic_page_buffer_resource,
 * IntrusiveArenaAllocator), so the linked app imports exactly two libc++
 * symbols that iOS 12.2's libc++.1.dylib does not export:
 *
 *   __ZTINSt3__13pmr15memory_resourceE   typeinfo
 *   __ZNSt3__13pmr15memory_resourceD2Ev  destructor
 *
 * The result is a launch failure, not a compile error:
 *   Termination Description: DYLD, Symbol not found:
 *   __ZTINSt3__13pmr15memory_resourceE | Expected in: /usr/lib/libc++.1.dylib
 *
 * <memory_resource> is header-only apart from this key function: the
 * destructor is declared out-of-line, so defining it here emits the
 * destructor, the vtable and the RTTI in this object, and dyld resolves all
 * three from the app itself. Nothing else in std::pmr is out-of-line here.
 *
 * Formally this defines a member of a standard library class, which the
 * standard leaves undefined; in practice it is the only way to supply a
 * runtime piece the OS predates, and the declaration it matches is the one
 * the SDK header ships.
 */
#include <cstddef>
#include <memory_resource>

namespace std {
inline namespace __1 {
namespace pmr {

memory_resource::~memory_resource() = default;

} // namespace pmr
} // inline namespace __1
} // namespace std
