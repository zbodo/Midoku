# Texture source dependency

Source from Skittyblock/Texture commit `6a6475db9bf9f7e04731ab60053c3ca4934c1ac6` (3.1.1), licensed under Apache 2.0; see LICENSE.

The upstream binary package contains only iOS device and simulator slices. This local Swift package builds the same Objective-C++ implementation for iOS and Mac Catalyst. The include directory contains relative header links for Texture’s existing framework-style imports.

Local source fix: ASTextLayout’s four chained comparisons are corrected to nearest-edge conditional expressions, as required by current Clang.
The OpenGL-layer special case is excluded on Catalyst, where CAEAGLLayer is unavailable.
