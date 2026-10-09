pub const a = 32;
const b = 43;
if (a != 32) { panic "pub const a"; }
if (b != 43) { panic "b"; }
{
	const a = 234;
	if (a != 234) { panic "shadow inner a"; }
	{
		const a = 1234;
		if (a != 1234) { panic "shadow deepest"; }
	}
	if (a != 234) { panic "shadow after deepest"; }
}
if (a != 32) { panic "outer a unchanged"; }

const c = 100;
if (c != 100) { panic "c"; }

const sum = 75;
if (sum != 75) { panic "sum const"; }

const str = "hello";
if (str != "hello") { panic "str const"; }
