# -*- coding: utf-8 -*-
"""用 Windows GDI 把字符栅格化成 16x16 点阵(不依赖 PIL, 不产生编译产物)"""
import ctypes, ctypes.wintypes as wt

_u32 = ctypes.WinDLL("user32", use_last_error=True)
_g32 = ctypes.WinDLL("gdi32", use_last_error=True)
P = ctypes.c_void_p

_u32.GetDC.restype = P;              _u32.GetDC.argtypes = [P]
_g32.CreateCompatibleDC.restype = P; _g32.CreateCompatibleDC.argtypes = [P]
_g32.CreateDIBSection.restype = P
_g32.CreateDIBSection.argtypes = [P, ctypes.c_void_p, ctypes.c_uint,
                                  ctypes.POINTER(P), P, ctypes.c_uint]
_g32.SelectObject.restype = P;       _g32.SelectObject.argtypes = [P, P]
_g32.CreateFontW.restype = P
_g32.CreateFontW.argtypes = [ctypes.c_int] * 5 + [ctypes.c_uint] * 8 + [ctypes.c_char_p]
_g32.SetBkMode.argtypes = [P, ctypes.c_int]
_g32.SetTextColor.argtypes = [P, ctypes.c_uint]
_g32.DeleteObject.argtypes = [P]
_u32.DrawTextW.argtypes = [P, ctypes.c_wchar_p, ctypes.c_int,
                           ctypes.POINTER(wt.RECT), ctypes.c_uint]

class _BIH(ctypes.Structure):
    _fields_ = [("biSize", wt.DWORD), ("biWidth", wt.LONG), ("biHeight", wt.LONG),
                ("biPlanes", wt.WORD), ("biBitCount", wt.WORD), ("biCompression", wt.DWORD),
                ("biSizeImage", wt.DWORD), ("biXPelsPerMeter", wt.LONG),
                ("biYPelsPerMeter", wt.LONG), ("biClrUsed", wt.DWORD),
                ("biClrImportant", wt.DWORD)]

class _BI(ctypes.Structure):
    _fields_ = [("bmiHeader", _BIH), ("bmiColors", wt.DWORD * 3)]

W = H = 16

class FontRaster:
    def __init__(self, face="SimSun", height=16):
        self.hdc = _g32.CreateCompatibleDC(_u32.GetDC(None))
        bi = _BI()
        bi.bmiHeader.biSize = ctypes.sizeof(_BIH)
        bi.bmiHeader.biWidth = W
        bi.bmiHeader.biHeight = -H
        bi.bmiHeader.biPlanes = 1
        bi.bmiHeader.biBitCount = 32
        self.ppv = P()
        hbmp = _g32.CreateDIBSection(self.hdc, ctypes.byref(bi), 0,
                                     ctypes.byref(self.ppv), None, 0)
        _g32.SelectObject(self.hdc, hbmp)
        self.hfont = _g32.CreateFontW(height, 0, 0, 0, 400, 0, 0, 0,
                                      134, 0, 0, 2, 0, face.encode("ascii"))
        _g32.SelectObject(self.hdc, self.hfont)
        _g32.SetBkMode(self.hdc, 1)
        _g32.SetTextColor(self.hdc, 0x00FFFFFF)

    def render(self, ch, double_ascii=True):
        """返回 16 个整数, 每个整数是 16 位行位图(bit15 在最左)"""
        ctypes.memset(self.ppv, 0, W * H * 4)
        r = wt.RECT(0, 0, W, H)
        _u32.DrawTextW(self.hdc, ch, 1, ctypes.byref(r), 0x00000010)
        buf = (ctypes.c_ubyte * (W * H * 4)).from_address(self.ppv.value)
        rows = []
        for y in range(H):
            v = 0
            for x in range(W):
                bit = 1 if buf[(y * W + x) * 4 + 1] > 96 else 0
                if double_ascii and ord(ch) < 128 and bit:
                    # ASCII 水平放大一倍, 填满 16 宽, 避免"字距拉太开"
                    v |= (1 << (15 - x))
                    v |= (1 << (15 - min(x + 1, 15)))
                elif bit:
                    v |= (1 << (15 - x))
            rows.append(v & 0xFFFF)
        return rows
