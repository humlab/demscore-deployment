# The seven quantile colours, in the three orders the legend can read them.
#
# INCLUDEd by every hex fill layer rather than written out per layer: one mesh is
# cut in Equal Earth and one in Web Mercator, and the projection a cell was cut
# in has nothing to do with the colour it takes. class_idx is shifted by the
# DATA query per polarity -- 1-7 negative, 8-x positive, 10+x neutral -- so the
# bar always reads low-to-high left to right.
  CLASS
    NAME "1"
    EXPRESSION ([class_idx] = 1)
    STYLE
      COLOR 49 54 149
      OUTLINECOLOR 255 255 255
      WIDTH 0.25
    END
  END

  CLASS
    NAME "2"
    EXPRESSION ([class_idx] = 2)
    STYLE
      COLOR 69 117 180
      OUTLINECOLOR 255 255 255
      WIDTH 0.25
    END
  END

  CLASS
    NAME "3"
    EXPRESSION ([class_idx] = 3)
    STYLE
      COLOR 116 173 209
      OUTLINECOLOR 255 255 255
      WIDTH 0.25
    END
  END

  CLASS
    NAME "4"
    EXPRESSION ([class_idx] = 4)
    STYLE
      COLOR 171 217 233
      OUTLINECOLOR 255 255 255
      WIDTH 0.25
    END
  END

  CLASS
    NAME "5"
    EXPRESSION ([class_idx] = 5)
    STYLE
      COLOR 253 174 97
      OUTLINECOLOR 255 255 255
      WIDTH 0.25
    END
  END

  CLASS
    NAME "6"
    EXPRESSION ([class_idx] = 6)
    STYLE
      COLOR 244 109 67
      OUTLINECOLOR 255 255 255
      WIDTH 0.25
    END
  END

  CLASS
    NAME "7"
    EXPRESSION ([class_idx] = 7)
    STYLE
      COLOR 215 48 39
      OUTLINECOLOR 255 255 255
      WIDTH 0.25
    END
  END

  CLASS
    NAME "neutral 1"
    EXPRESSION ([class_idx] = 11)
    STYLE
      COLOR 209 250 229
      OUTLINECOLOR 255 255 255
      WIDTH 0.25
    END
  END

  CLASS
    NAME "neutral 2"
    EXPRESSION ([class_idx] = 12)
    STYLE
      COLOR 167 243 208
      OUTLINECOLOR 255 255 255
      WIDTH 0.25
    END
  END

  CLASS
    NAME "neutral 3"
    EXPRESSION ([class_idx] = 13)
    STYLE
      COLOR 110 231 183
      OUTLINECOLOR 255 255 255
      WIDTH 0.25
    END
  END

  CLASS
    NAME "neutral 4"
    EXPRESSION ([class_idx] = 14)
    STYLE
      COLOR 52 211 153
      OUTLINECOLOR 255 255 255
      WIDTH 0.25
    END
  END

  CLASS
    NAME "neutral 5"
    EXPRESSION ([class_idx] = 15)
    STYLE
      COLOR 16 185 129
      OUTLINECOLOR 255 255 255
      WIDTH 0.25
    END
  END

  CLASS
    NAME "neutral 6"
    EXPRESSION ([class_idx] = 16)
    STYLE
      COLOR 5 150 105
      OUTLINECOLOR 255 255 255
      WIDTH 0.25
    END
  END

  CLASS
    NAME "neutral 7"
    EXPRESSION ([class_idx] = 17)
    STYLE
      COLOR 4 120 87
      OUTLINECOLOR 255 255 255
      WIDTH 0.25
    END
  END
