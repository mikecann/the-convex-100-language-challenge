note
	description: "Temporary smoke-test root used only while bringing up the toolchain; replaced by CONVEX_JSON_TESTS once the ECF plumbing is verified."

class
	CONVEX_TEST_APP

create
	make

feature {NONE} -- Initialization

	make
		local
			sock: CONVEX_SOCKET
		do
			create sock.make ("example.com", 443, True)
			print (sock.is_open.out)
			print ("%N")
			print ("SMOKE_OK%N")
		end

end
