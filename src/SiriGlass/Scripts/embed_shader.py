#!/usr/bin/env python3
"""Regenerates Sources/SiriGlass/Shaders/SiriGlassShader.swift from SiriGlass.metal.txt.

The shader is compiled at runtime from this string (a tweak's dylib has no
resource bundle), so edit SiriGlass.metal.txt and run this."""
import pathlib
root = pathlib.Path(__file__).resolve().parent.parent / "Sources/SiriGlass"
src = (root / "SiriGlass.metal.txt").read_text()
assert '"""#' not in src
(root / "Shaders/SiriGlassShader.swift").write_text('''//
//  SiriGlassShader.swift
//  SiriGlass
//
//  Generated from SiriGlass.metal.txt by Scripts/embed_shader.py.
//

let siriGlassShaderSource = #"""
''' + src + '''
"""#
''')
