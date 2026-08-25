if ((10 & 1) != 0) { panic "&"; }
if ((1 | 2) != 3) { panic "|"; }
if ((1 << 2) != 4) { panic "<<"; }
if ((2 >> 1) != 1) { panic ">>"; }
if ((1 ^ 2) != 3) { panic "^"; }
if ((~3) != -4) { panic "~"; }

var a = 12;
var b = 10;
if ((a & b) != 8) { panic "a & b"; }
if ((a | b) != 14) { panic "a | b"; }
if ((a ^ b) != 6) { panic "a ^ b"; }

var shifted = 5 << 1;
if (shifted != 10) { panic "shifted"; }
shifted = 10 >> 2;
if (shifted != 2) { panic "shr"; }

var notted = ~0;
if (notted != -1) { panic "~0"; }

if ((5 & 3) != 1) { panic "5&3"; }
if ((5 | 2) != 7) { panic "5|2"; }
