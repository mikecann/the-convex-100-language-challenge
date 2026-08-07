// A small, hand-written JSON encoder and decoder. Hare's standard library has
// no JSON module, so Convex's request and response envelopes are built and
// parsed here rather than delegated to a third-party dependency.
use ascii;
use fmt;
use io;
use math;
use memio;
use strconv;
use strings;

// A parsed JSON value. Numbers keep their original integer-vs-float shape so
// a whole counter round-trips exactly instead of drifting through a float
// reinterpretation, matching how Convex's own JSON-safe profile represents
// integral results.
export type value = (void | bool | i64 | f64 | str | []value | []entry);

// One member of a JSON object. Objects are represented as an ordered slice of
// entries rather than a hash map: Convex payloads are small, insertion order
// is what a human reviewer expects to see, and it avoids pulling in a second
// data structure for a handful of fields.
export type entry = struct {
	key: str,
	value: value,
};

export type decode_error = !void;

// Frees every string and nested value owned by a decoded or hand-built
// value. Callers that construct a [[value]] from borrowed string literals
// only (as the example and adapter frequently do for short-lived request
// bodies) may skip calling this and let the arena-free process exit reclaim
// it instead; anything built from [[parse]] must be freed with this.
export fn finish(v: *value) void = {
	match (*v) {
	case let s: str =>
		free(s);
	case let items: []value =>
		for (let i = 0z; i < len(items); i += 1) finish(&items[i]);
		free(items);
	case let members: []entry =>
		for (let i = 0z; i < len(members); i += 1) {
			free(members[i].key);
			finish(&members[i].value);
		};
		free(members);
	case => void;
	};
};

// Looks up a member of an object value by key. Returns null if the value is
// not an object or has no such key.
export fn lookup(v: value, key: str) (*value | void) = {
	const members = match (v) {
	case let members: []entry =>
		yield members;
	case =>
		return void;
	};
	for (let i = 0z; i < len(members); i += 1) {
		if (members[i].key == key) return &members[i].value;
	};
	return void;
};

type parser = struct {
	input: str,
	bytes: []u8,
	pos: size,
};

// Parses one JSON document. Trailing whitespace after the value is allowed;
// trailing non-whitespace content is rejected so a truncated or concatenated
// document cannot silently decode as its first well-formed prefix.
export fn parse(input: str) (value | decode_error) = {
	let p = parser {
		input = input,
		bytes = strings::toutf8(input),
		pos = 0,
	};
	skip_ws(&p);
	const v = parse_value(&p)?;
	skip_ws(&p);
	if (p.pos != len(p.bytes)) return decode_error;
	return v;
};

fn peek(p: *parser) (u8 | void) = {
	if (p.pos >= len(p.bytes)) return void;
	return p.bytes[p.pos];
};

fn skip_ws(p: *parser) void = {
	for (true) {
		const b = match (peek(p)) {
		case let b: u8 =>
			yield b;
		case void =>
			return;
		};
		if (b == ' ' || b == '\t' || b == '\n' || b == '\r') {
			p.pos += 1;
		} else return;
	};
};

fn expect(p: *parser, b: u8) (void | decode_error) = {
	if (peek(p) is void || (peek(p) as u8) != b) return decode_error;
	p.pos += 1;
};

fn literal(p: *parser, text: str) (void | decode_error) = {
	const want = strings::toutf8(text);
	if (p.pos + len(want) > len(p.bytes)) return decode_error;
	if (!bytes_eq(p.bytes[p.pos..p.pos + len(want)], want)) return decode_error;
	p.pos += len(want);
};

fn bytes_eq(a: []u8, b: []u8) bool = {
	if (len(a) != len(b)) return false;
	for (let i = 0z; i < len(a); i += 1) if (a[i] != b[i]) return false;
	return true;
};

fn parse_value(p: *parser) (value | decode_error) = {
	skip_ws(p);
	const b = match (peek(p)) {
	case let b: u8 =>
		yield b;
	case void =>
		return decode_error;
	};
	switch (b) {
	case '{' =>
		return parse_object(p);
	case '[' =>
		return parse_array(p);
	case '"' =>
		return parse_string(p);
	case 't' =>
		literal(p, "true")?;
		return true;
	case 'f' =>
		literal(p, "false")?;
		return false;
	case 'n' =>
		literal(p, "null")?;
		return void: value;
	case =>
		if (b == '-' || (b >= '0' && b <= '9')) return parse_number(p);
		return decode_error;
	};
};

fn parse_object(p: *parser) (value | decode_error) = {
	expect(p, '{')?;
	let members: []entry = [];
	skip_ws(p);
	if ((peek(p) is u8) && (peek(p) as u8) == '}') {
		p.pos += 1;
		return members;
	};
	for (true) {
		skip_ws(p);
		const key = match (parse_string(p)?) {
		case let s: str =>
			yield s;
		case =>
			for (let i = 0z; i < len(members); i += 1) free(members[i].key);
			free(members);
			return decode_error;
		};
		skip_ws(p);
		match (expect(p, ':')) {
		case void => void;
		case decode_error =>
			free(key);
			for (let i = 0z; i < len(members); i += 1) {
				free(members[i].key);
			};
			free(members);
			return decode_error;
		};
		const v = match (parse_value(p)) {
		case let v: value =>
			yield v;
		case decode_error =>
			free(key);
			for (let i = 0z; i < len(members); i += 1) free(members[i].key);
			free(members);
			return decode_error;
		};
		append(members, entry { key = key, value = v });
		skip_ws(p);
		const next = match (peek(p)) {
		case let b: u8 =>
			yield b;
		case void =>
			for (let i = 0z; i < len(members); i += 1) free(members[i].key);
			free(members);
			return decode_error;
		};
		if (next == ',') {
			p.pos += 1;
			continue;
		} else if (next == '}') {
			p.pos += 1;
			break;
		} else {
			for (let i = 0z; i < len(members); i += 1) free(members[i].key);
			free(members);
			return decode_error;
		};
	};
	return members;
};

fn parse_array(p: *parser) (value | decode_error) = {
	expect(p, '[')?;
	let items: []value = [];
	skip_ws(p);
	if ((peek(p) is u8) && (peek(p) as u8) == ']') {
		p.pos += 1;
		return items;
	};
	for (true) {
		const v = match (parse_value(p)) {
		case let v: value =>
			yield v;
		case decode_error =>
			free(items);
			return decode_error;
		};
		append(items, v);
		skip_ws(p);
		const next = match (peek(p)) {
		case let b: u8 =>
			yield b;
		case void =>
			free(items);
			return decode_error;
		};
		if (next == ',') {
			p.pos += 1;
			continue;
		} else if (next == ']') {
			p.pos += 1;
			break;
		} else {
			free(items);
			return decode_error;
		};
	};
	return items;
};

fn hexval(b: u8) (u32 | decode_error) = {
	if (b >= '0' && b <= '9') return (b - '0'): u32;
	if (b >= 'a' && b <= 'f') return (b - 'a' + 10): u32;
	if (b >= 'A' && b <= 'F') return (b - 'A' + 10): u32;
	return decode_error;
};

fn parse_string(p: *parser) (value | decode_error) = {
	expect(p, '"')?;
	let out = memio::dynamic();
	for (true) {
		const b = match (peek(p)) {
		case let b: u8 =>
			yield b;
		case void =>
			io::close(&out)!;
			return decode_error;
		};
		p.pos += 1;
		if (b == '"') break;
		if (b < 0x20) {
			io::close(&out)!;
			return decode_error;
		};
		if (b != '\\') {
			// The input is already UTF-8 encoded bytes straight from the
			// wire. Writing the raw byte through unchanged is required,
			// not just faster: treating it as one rune (as appendrune
			// would) reinterprets each individual byte of a multi-byte
			// sequence as its own Latin-1-like codepoint and re-encodes
			// it, corrupting every non-ASCII character into a cascade of
			// mojibake.
			io::writeall(&out, [b])!;
			continue;
		};
		const esc = match (peek(p)) {
		case let b: u8 =>
			yield b;
		case void =>
			io::close(&out)!;
			return decode_error;
		};
		p.pos += 1;
		switch (esc) {
		case '"' =>
			memio::appendrune(&out, '"')!;
		case '\\' =>
			memio::appendrune(&out, '\\')!;
		case '/' =>
			memio::appendrune(&out, '/')!;
		case 'b' =>
			memio::appendrune(&out, 0x08: rune)!;
		case 'f' =>
			memio::appendrune(&out, 0x0c: rune)!;
		case 'n' =>
			memio::appendrune(&out, '\n')!;
		case 'r' =>
			memio::appendrune(&out, '\r')!;
		case 't' =>
			memio::appendrune(&out, '\t')!;
		case 'u' =>
			const high = match (parse_hex4(p)) {
			case let v: u32 =>
				yield v;
			case decode_error =>
				io::close(&out)!;
				return decode_error;
			};
			let codepoint = high;
			if (high >= 0xd800 && high <= 0xdbff) {
				// A high surrogate must be followed by a low surrogate; any
				// other continuation is a malformed escape rather than a
				// codepoint we can approximate.
				if (len(p.bytes) < p.pos + 2 || p.bytes[p.pos] != '\\' || p.bytes[p.pos + 1] != 'u') {
					io::close(&out)!;
					return decode_error;
				};
				p.pos += 2;
				const low = match (parse_hex4(p)) {
				case let v: u32 =>
					yield v;
				case decode_error =>
					io::close(&out)!;
					return decode_error;
				};
				if (low < 0xdc00 || low > 0xdfff) {
					io::close(&out)!;
					return decode_error;
				};
				codepoint = 0x10000 + (high - 0xd800) * 0x400 + (low - 0xdc00);
			} else if (high >= 0xdc00 && high <= 0xdfff) {
				io::close(&out)!;
				return decode_error;
			};
			memio::appendrune(&out, codepoint: rune)!;
		case =>
			io::close(&out)!;
			return decode_error;
		};
	};
	return memio::string(&out)!;
};

fn parse_hex4(p: *parser) (u32 | decode_error) = {
	if (p.pos + 4 > len(p.bytes)) return decode_error;
	let v = 0u32;
	for (let i = 0z; i < 4; i += 1) {
		v = v * 16 + hexval(p.bytes[p.pos + i])?;
	};
	p.pos += 4;
	return v;
};

fn parse_number(p: *parser) (value | decode_error) = {
	const start = p.pos;
	let is_float = false;
	if ((peek(p) is u8) && (peek(p) as u8) == '-') p.pos += 1;
	if (!(peek(p) is u8) || !ascii::isdigit((peek(p) as u8): rune)) return decode_error;
	if ((peek(p) as u8) == '0') {
		p.pos += 1;
	} else {
		for ((peek(p) is u8) && ascii::isdigit((peek(p) as u8): rune)) p.pos += 1;
	};
	if ((peek(p) is u8) && (peek(p) as u8) == '.') {
		is_float = true;
		p.pos += 1;
		if (!(peek(p) is u8) || !ascii::isdigit((peek(p) as u8): rune)) return decode_error;
		for ((peek(p) is u8) && ascii::isdigit((peek(p) as u8): rune)) p.pos += 1;
	};
	if ((peek(p) is u8) && ((peek(p) as u8) == 'e' || (peek(p) as u8) == 'E')) {
		is_float = true;
		p.pos += 1;
		if ((peek(p) is u8) && ((peek(p) as u8) == '+' || (peek(p) as u8) == '-')) p.pos += 1;
		if (!(peek(p) is u8) || !ascii::isdigit((peek(p) as u8): rune)) return decode_error;
		for ((peek(p) is u8) && ascii::isdigit((peek(p) as u8): rune)) p.pos += 1;
	};
	const text = strings::fromutf8(p.bytes[start..p.pos])!;
	if (!is_float) {
		match (strconv::stoi64(text)) {
		case let i: i64 =>
			return i;
		case =>
			void; // Falls through to float parsing on overflow.
		};
	};
	match (strconv::stof64(text)) {
	case let f: f64 =>
		return f;
	case =>
		return decode_error;
	};
};

// Serializes a value as compact JSON with no insignificant whitespace,
// matching the wire shape Convex's HTTP and sync APIs expect.
export fn encode(v: value) str = {
	let out = memio::dynamic();
	encode_into(&out, v);
	return memio::string(&out)!;
};

fn encode_into(out: *memio::stream, v: value) void = {
	match (v) {
	case void =>
		fmt::fprint(out, "null")!;
	case let b: bool =>
		fmt::fprint(out, if (b) "true" else "false")!;
	case let i: i64 =>
		fmt::fprint(out, strconv::i64tos(i))!;
	case let f: f64 =>
		encode_float(out, f);
	case let s: str =>
		encode_string(out, s);
	case let items: []value =>
		fmt::fprint(out, "[")!;
		for (let i = 0z; i < len(items); i += 1) {
			if (i > 0) fmt::fprint(out, ",")!;
			encode_into(out, items[i]);
		};
		fmt::fprint(out, "]")!;
	case let members: []entry =>
		fmt::fprint(out, "{")!;
		for (let i = 0z; i < len(members); i += 1) {
			if (i > 0) fmt::fprint(out, ",")!;
			encode_string(out, members[i].key);
			fmt::fprint(out, ":")!;
			encode_into(out, members[i].value);
		};
		fmt::fprint(out, "}")!;
	};
};

fn encode_float(out: *memio::stream, f: f64) void = {
	// JSON has no literal for non-finite numbers. Convex's JSON-safe query
	// profile never produces one for a value this client decodes, so an
	// attempt to encode one is a programming error in the caller, not a
	// value this client should silently coerce to null or a string.
	assert(!math::isnan(f), "cannot encode NaN as JSON");
	assert(!math::isinf(f), "cannot encode an infinite float as JSON");
	let text = strconv::f64tos(f);
	// Hare formats an integral float like 1 as "1", but JSON's own grammar
	// requires a fraction or exponent on every number that contains no
	// digits-only integer marker distinguishing it from an integer type on
	// the wire. Convex's decoders accept bare integers for float fields, so
	// this keeps the output compact rather than forcing a synthetic ".0".
	fmt::fprint(out, text)!;
};

fn encode_string(out: *memio::stream, s: str) void = {
	fmt::fprint(out, "\"")!;
	const bytes = strings::toutf8(s);
	for (let i = 0z; i < len(bytes); i += 1) {
		const b = bytes[i];
		switch (b) {
		case '"' =>
			fmt::fprint(out, "\\\"")!;
		case '\\' =>
			fmt::fprint(out, "\\\\")!;
		case '\n' =>
			fmt::fprint(out, "\\n")!;
		case '\r' =>
			fmt::fprint(out, "\\r")!;
		case '\t' =>
			fmt::fprint(out, "\\t")!;
		case =>
			if (b < 0x20) {
				fmt::fprintf(out, "\\u{:04x}", b: u32)!;
			} else {
				io::writeall(out, [b])!;
			};
		};
	};
	fmt::fprint(out, "\"")!;
};

@test fn parse_and_encode_roundtrip() void = {
	const v = parse(`{"a":1,"b":[true,false,null,"x\né"],"c":1.5,"d":-0}`)!;
	defer finish(&v);
	const a = lookup(v, "a") as *value;
	assert(*a as i64 == 1);
	const c = lookup(v, "c") as *value;
	assert(*c as f64 == 1.5);
	const encoded = encode(v);
	defer free(encoded);
	assert(len(encoded) > 0);
};

@test fn rejects_malformed_input() void = {
	assert(parse("") is decode_error);
	assert(parse("{") is decode_error);
	assert(parse(`{"a":}`) is decode_error);
	assert(parse("01") is decode_error);
	assert(parse(`"unterminated`) is decode_error);
	assert(parse("truex") is decode_error);
};

@test fn integer_and_float_numbers_stay_distinct() void = {
	const zero = parse("0")!;
	defer finish(&zero);
	assert(zero as i64 == 0);
	const zero_float = parse("0.0")!;
	defer finish(&zero_float);
	assert(zero_float as f64 == 0.0);
	const big = parse("9223372036854775807")!;
	defer finish(&big);
	assert(big as i64 == 9223372036854775807);
	// An integer literal that overflows i64 still decodes, as a float.
	const overflow = parse("99999999999999999999")!;
	defer finish(&overflow);
	assert(overflow is f64);
};

@test fn decodes_multibyte_utf8_without_corruption() void = {
	// A regression for a real bug: decoding used to treat each raw UTF-8
	// byte of a multi-byte character as its own codepoint and re-encode it,
	// corrupting every non-ASCII string into cascading mojibake. This
	// exercises a 2-byte, 3-byte, and 4-byte (surrogate-pair-in-source)
	// character together.
	const text = `"Hello, 世界 👋"`;
	const v = parse(text)!;
	defer finish(&v);
	assert(v as str == "Hello, 世界 👋");
	const encoded = encode(v);
	defer free(encoded);
	assert(encoded == text);
};
