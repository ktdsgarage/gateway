package com.telecom.gateway.tech.service;

import com.telecom.gateway.common.dto.SupportRequest;
import com.telecom.gateway.common.dto.SupportResponse;
import com.telecom.gateway.common.model.SupportHistory;
import com.telecom.gateway.tech.repository.TechRepository;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.stereotype.Service;

import java.time.LocalDateTime;
import java.util.UUID;

@Slf4j
@Service
@RequiredArgsConstructor
public class TechService {
    private final TechRepository techRepository;

    public SupportResponse processTechSupport(SupportRequest request) {
        // 문의 이력 저장
        SupportHistory history = SupportHistory.builder()
                .id(UUID.randomUUID().toString())
                .customerId(request.getCustomerId())
                .content(request.getContent())
                .type("TECH")
                .status("COMPLETED")
                .result("기술문의가 정상적으로 처리되었습니다.")
                .createdAt(LocalDateTime.now())
                .processedAt(LocalDateTime.now())
                .build();
        
        techRepository.save(history);
        
        return SupportResponse.builder()
                .inquiryId(history.getId())
                .status(history.getStatus())
                .result(history.getResult())
                .processedAt(history.getProcessedAt())
                .build();
    }

    public SupportHistory getTechSupport(String inquiryId) {
        return techRepository.findById(inquiryId)
                .orElseThrow(() -> new RuntimeException("문의를 찾을 수 없습니다."));
    }
}


